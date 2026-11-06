"""Multi-GPU single-node LoRA fine-tune for SkySpot recipe 02.

Launched via `torchrun --nproc_per_node=<gpus>`; Hugging Face Trainer then runs
DistributedDataParallel across all GPUs on the node automatically. Data is read
from /data (S3) and the adapter is written to /outputs (S3) by rank 0 only.

For very large base models, switch DDP to FSDP by passing `--fsdp` style args
through TrainingArguments (see the commented fsdp block below).
"""
import os
import time

import torch
from datasets import load_dataset
from peft import LoraConfig, get_peft_model
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    DataCollatorForLanguageModeling,
    Trainer,
    TrainingArguments,
)

MODEL = os.environ.get("MODEL_NAME", "Qwen/Qwen3.5-4B")
DATA_FILE = os.environ.get("DATA_FILE", "").strip()
OUTPUT_ROOT = "/outputs/runs"


def load_data():
    if DATA_FILE:
        path = os.path.join("/data", DATA_FILE)
        return load_dataset("json", data_files=path, split="train")
    return load_dataset("tatsu-lab/alpaca", split="train[:2000]")


def main():
    assert torch.cuda.is_available(), "No GPU visible - aborting"
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    if local_rank == 0:
        print(f"GPUs per node: {torch.cuda.device_count()}", flush=True)

    # One shared run dir for all ranks; only rank 0 writes the final adapter.
    run_id = os.environ.get("SKYSPOT_RUN_ID") or time.strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.join(OUTPUT_ROOT, run_id)

    tok = AutoTokenizer.from_pretrained(MODEL)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    model = AutoModelForCausalLM.from_pretrained(MODEL, torch_dtype=torch.bfloat16)
    model = get_peft_model(
        model,
        LoraConfig(
            r=16,
            lora_alpha=32,
            lora_dropout=0.05,
            task_type="CAUSAL_LM",
            target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
        ),
    )
    if local_rank == 0:
        model.print_trainable_parameters()
    # Gradient checkpointing keeps activations in check on 24GB cards; the
    # enable_input_require_grads() call is required for it to work with LoRA.
    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()

    ds = load_data()

    def fmt(ex):
        inp = ex.get("input", "") or ""
        prompt = ex["instruction"] + (("\n" + inp) if inp else "")
        text = (
            f"<|im_start|>user\n{prompt}<|im_end|>\n"
            f"<|im_start|>assistant\n{ex['output']}<|im_end|>"
        )
        return tok(text, truncation=True, max_length=1024)

    ds = ds.map(fmt, remove_columns=ds.column_names)

    args = TrainingArguments(
        output_dir=out_dir,
        num_train_epochs=1,
        per_device_train_batch_size=2,
        gradient_accumulation_steps=2,
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        learning_rate=2e-4,
        bf16=True,
        logging_steps=10,
        save_strategy="steps",
        save_steps=200,
        ddp_find_unused_parameters=False,
        report_to=[],
        # For a base model too big to replicate per GPU, use FSDP instead of DDP:
        # fsdp="full_shard auto_wrap",
        # fsdp_config={"transformer_layer_cls_to_wrap": ["Qwen3DecoderLayer"]},
    )
    trainer = Trainer(
        model=model,
        args=args,
        train_dataset=ds,
        data_collator=DataCollatorForLanguageModeling(tok, mlm=False),
    )
    trainer.train()

    if trainer.is_world_process_zero():
        model.save_pretrained(out_dir)
        tok.save_pretrained(out_dir)
        print(f"TRAINING COMPLETE OK - weights written to s3 via {out_dir}", flush=True)


if __name__ == "__main__":
    main()
