"""Fixed-window language evaluation and local ImageNet evaluation."""
import math
import torch


def token_windows(tokens, context, windows):
    if context < 2 or windows < 1:
        raise ValueError("context >= 2 and windows >= 1 are required")
    # Disjoint windows; every mode scores the exact same token transitions.
    available = min(windows, len(tokens) // context)
    if available == 0:
        raise ValueError("Dataset has fewer than one full context window")
    return [torch.tensor(tokens[i * context:(i + 1) * context], dtype=torch.long)
            for i in range(available)]


def perplexity(model, windows, device):
    loss_sum, count = 0.0, 0
    losses, token_counts = [], []
    with torch.inference_mode():
        for window in windows:
            ids = window.unsqueeze(0).to(device)
            logits = model(input_ids=ids, use_cache=False).logits
            loss = torch.nn.functional.cross_entropy(
                logits[:, :-1].reshape(-1, logits.shape[-1]), ids[:, 1:].reshape(-1),
                reduction="sum")
            if not bool(torch.isfinite(loss)):
                raise RuntimeError("Nonfinite language-model loss")
            loss_sum += loss.item()
            tokens = ids.numel() - ids.shape[0]
            count += tokens
            losses.append(loss.item())
            token_counts.append(tokens)
    if count == 0:
        raise ValueError("No tokens were scored")
    nll = loss_sum / count
    ppl = math.exp(nll)
    if not math.isfinite(ppl):
        raise RuntimeError("Nonfinite perplexity")
    return {"nll": nll, "perplexity": ppl, "scored_tokens": count,
            "windows": len(windows),
            "observations": {"unit": "text_window", "loss_sums": losses,
                             "token_counts": token_counts}}


def classification(model, batches, device):
    top1, top5, count = 0, 0, 0
    top1_correct, top5_correct = [], []
    with torch.inference_mode():
        for pixels, labels in batches:
            logits = model(pixel_values=pixels.to(device)).logits
            if not bool(torch.isfinite(logits).all()):
                raise RuntimeError("Nonfinite classification logits")
            targets = labels.to(device).view(-1, 1)
            predictions = logits.topk(min(5, logits.shape[-1]), dim=-1).indices
            correct1 = (predictions[:, :1] == targets).flatten()
            correct5 = (predictions == targets).any(-1)
            top1 += correct1.sum().item()
            top5 += correct5.sum().item()
            top1_correct.extend(correct1.cpu().tolist())
            top5_correct.extend(correct5.cpu().tolist())
            count += len(labels)
    if not count:
        raise ValueError("No classification samples")
    return {"top1_percent": 100 * top1 / count, "top5_percent": 100 * top5 / count,
            "samples": count,
            "observations": {"unit": "image", "top1_correct": top1_correct,
                             "top5_correct": top5_correct}}
