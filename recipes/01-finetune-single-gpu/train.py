"""Single-GPU LoRA fine-tune for SkySpot recipe 01.

Reads training data from the S3 bucket mounted at /data and writes the trained
LoRA adapter to the S3 bucket mounted at /outputs. Writing to /outputs (an S3
MOUNT) means weights are durable across spot preemptions.

Data format: a JSONL file where each line is
    {"instruction": "...", "input": "", "output": "..."}
Set DATA_FILE to its path under /data. If DATA_FILE is empty, a small public
dataset is used so you can smoke-test the whole pipeline end to end.
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
    """Customer data from /data if provided, else a public demo dataset."""
    if DATA_FILE:
        path = os.path.join("/data", DATA_FILE)
        print(f"Loading training data from {path}", flush=True)
        return load_dataset("json", data_files=path, split="train")
    print("DATA_FILE empty - using public demo dataset tatsu-lab/alpaca[:500]", flush=True)
    return load_dataset("tatsu-lab/alpaca", split="train[:500]")


def main():
    assert torch.cuda.is_available(), "No GPU visible - aborting"
    print(f"GPU: {torch.cuda.get_device_name(0)}", flush=True)

    run_id = time.strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.join(OUTPUT_ROOT, run_id)
    os.makedirs(out_dir, exist_ok=True)

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
    model.print_trainable_parameters()
    # Gradient checkpointing keeps a ~4B model's activations within a 24GB card
    # (g5/g6). enable_input_require_grads() is required for it to work with LoRA.
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
        # Small batch + gradient checkpointing so a ~4B model fits a 24GB GPU.
        # On a bigger card (g7e 96GB / g6e 48GB) you can raise the batch size.
        per_device_train_batch_size=2,
        gradient_accumulation_steps=8,
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        learning_rate=2e-4,
        bf16=True,
        logging_steps=10,
        # Checkpoint to the S3-backed /outputs so a preemption can be resumed.
        save_strategy="steps",
        save_steps=100,
        report_to=[],
    )
    trainer = Trainer(
        model=model,
        args=args,
        train_dataset=ds,
        data_collator=DataCollatorForLanguageModeling(tok, mlm=False),
    )
    trainer.train()

    # Final adapter + tokenizer -> S3.
    model.save_pretrained(out_dir)
    tok.save_pretrained(out_dir)
    print(f"TRAINING COMPLETE OK - weights written to s3 via {out_dir}", flush=True)


if __name__ == "__main__":
    main()
