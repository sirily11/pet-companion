#!/usr/bin/env python3
"""Export trained, unpadded PyTorch oracle fixtures for the native MLX test.

Install the pinned reference dependencies into an isolated environment, fetch
jev/{api,model,metrics}.py at reference commit
80ca8e81d08992cb2a4cbb6a0caa1355ad3e5aee into --reference-source, and download
all files in OpenJevManifest.json into --model-directory. No cloud calls.
"""
import os
import argparse
import json
import pathlib
import shutil
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--model-directory', type=pathlib.Path, required=True)
parser.add_argument('--reference-source', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--device', default='mps')
parser.add_argument('--dtype', default='float32', choices=['float32', 'bfloat16'])
args = parser.parse_args()
os.environ['JEV_TORCH_DTYPE'] = args.dtype
root = pathlib.Path(__file__).resolve().parents[2]
model_root = args.model_directory.resolve()
poses = json.loads((root / 'companions/orange-kitten/poses.json').read_text())
personality = json.loads((root / 'companions/orange-kitten/personality.json').read_text())
personality['name'] = 'Orange Kitten'
animations = {
    'still': 'Stay still and express the reaction through the chosen pose. Suitable for a reserved, tired, or unimpressed pet.',
    'touch': 'A small head dip and gentle squish to acknowledge contact.',
    'bounce': 'A brief cheerful hop and paw lift.',
    'nuzzle': 'A relaxed head sway and gentle squish, like leaning into affection.',
    'cuddle': 'A sustained affectionate head sway while the user holds the pet.',
    'play': 'A playful lean and paw lift, following the swipe direction when supplied.',
}
questions = {
    'pose': {'type': 'choice', 'instructions': "Choose the pet's reaction pose for the latest interaction. Use the full personality and the last 10 interactions, ordered oldest to newest, to decide how this particular pet feels. Repeated attention can change its reaction. Honor explicit pose requests in conversation. Choose idle if unclear. Never invent a pose.", 'criteria': {p['id']: p['criteria'] for p in poses}},
    'animation': {'type': 'choice', 'instructions': 'Choose how the pet physically reacts to the latest interaction, using its personality and recent history. A gesture does not require a particular animation: the pet may enjoy, ignore, or tire of attention. Choose still if unclear.', 'criteria': animations},
}
def event(kind, text, surface='editor', **extra):
    return dict(kind=kind, surface=surface, role='user', text=text, **extra)
scenarios = [
    ('tap', [event('tap', 'Clicked or tapped the pet.')]),
    ('touch', [event('touch', 'Gently touched the pet.')]),
    ('stroke', [event('stroke', 'Slowly stroked the pet.')]),
    ('held-cuddle', [event('cuddle', 'Held the pet in a cuddle.', 'desktop')]),
    ('swipe', [event('swipe', 'Swiped across the pet.', 'desktop', direction=[1, 0])]),
    ('explicit-pose', [event('conversation', 'Please use the sleepy pose.', 'conversation')]),
    ('chinese', [event('conversation', '我今天很累，想抱抱你。', 'conversation')]),
    ('mixed-ten', [event('tap', 'Clicked or tapped the pet.', 'desktop') if i % 3 == 0 else event('conversation', f'Hello kitten, this is turn {i}.', 'conversation') for i in range(9)] + [event('conversation', 'Show your excited pose!', 'conversation')]),
]
with tempfile.TemporaryDirectory(prefix='openjev-reference-') as tmp:
    package = pathlib.Path(tmp) / 'jev'; package.mkdir(); (package / '__init__.py').write_text('')
    for name in ('api.py', 'model.py', 'metrics.py'):
        shutil.copy2(args.reference_source / name, package / name)
    sys.path.insert(0, tmp)
    from jev.api import compile_request, candidate_prompts
    from jev.metrics import softmax
    from jev.model import DecisionModel
    import torch
    checkpoint = pathlib.Path(tmp) / 'checkpoint'
    shutil.copytree(model_root / 'checkpoint', checkpoint)
    config = json.loads((checkpoint / 'model.json').read_text())
    config['model_id'] = str(model_root / 'base')
    (checkpoint / 'model.json').write_text(json.dumps(config))
    started = time.perf_counter()
    model = DecisionModel.load(checkpoint, device=args.device)
    temperature = json.loads((checkpoint / 'temperature.json').read_text())['temperature']
    print('Reference loaded in', round(time.perf_counter() - started, 2), 'seconds', flush=True)
    fixtures = []
    for name, interactions in scenarios:
        state = dict(personality=personality, interactions=interactions)
        for record in compile_request(state, questions):
            prompts = candidate_prompts(record)
            scores, token_ids = [], []
            for option in record['options']:
                single = dict(record, options=[option])
                prompt = candidate_prompts(single)[0]
                encoded = model.tokenizer.apply_chat_template([{'role': 'user', 'content': prompt}], tokenize=True, add_generation_prompt=True, enable_thinking=False)
                token_ids.append(encoded['input_ids'] if hasattr(encoded, 'keys') else encoded)
                with torch.inference_mode():
                    scores.append(float(model([single])[0][0].float().cpu()))
            fixtures.append(dict(name=name + '-' + record['id'], state=state, question=questions[record['id']], prompts=prompts, tokenIDs=token_ids, scores=scores, probabilities=softmax(scores, temperature)))
            print(fixtures[-1]['name'], 'complete', flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(referenceCommit='80ca8e81d08992cb2a4cbb6a0caa1355ad3e5aee', checkpointRevision='0c7aa498b1627be8da4acf34c863ff0ee0a92785', baseRevision='15852e8c16360a2fea060d615a32b45270f8a8fc', device=args.device, dtype=str(next(model.backbone.parameters()).dtype), temperature=temperature, fixtures=fixtures), ensure_ascii=False, indent=2) + '\n')
