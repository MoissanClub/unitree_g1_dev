#!/usr/bin/env python3
"""Clean up recorded G1 microphone audio (robot motor noise) with a neural denoiser.

WHY
---
While the arms move, the G1's own actuators add tonal/broadband noise to the microphone
stream (see "Recording Audio" in pc2/vr_teleops/README.md). Classic filters cannot separate
that from speech because the noise changes with joint speed, so this script runs a speech
enhancement network instead and then brings the speech up to a usable loudness.

This is an OFFLINE post-processing tool for a laptop or desktop (nothing here runs on the
robot). The input file is never modified; a new WAV is written next to it. Keep the raw
recording as the ground-truth data and use the cleaned copy for listening or demos.

ENGINES (choose with --engine)
------------------------------
  rnnoise         Xiph RNNoise via the `pyrnnoise` package. Tiny, CPU-only, installs everywhere
                  (including macOS and Apple Silicon). Somewhat aggressive: it can make speech
                  slightly "gated" and it leaves some noise inside speech.
  deepfilternet   DeepFilterNet3 via the `deepfilternet` package (PyTorch). Higher quality,
                  keeps speech more natural. Fast enough on a CPU for short clips; it uses an
                  NVIDIA GPU automatically when CUDA is available (set CUDA_VISIBLE_DEVICES=""
                  to force the CPU). Downloads its model (~10 MB) on first use.
  both            Run the two engines and write one output per engine, to compare by ear.

Both networks work at 48 kHz. The recordings are 16 kHz, so the audio is resampled to 48 kHz,
enhanced, resampled back to 16 kHz, and the output has exactly the same number of samples as
the input (so it stays in sync with the video, like the raw audio.wav).

After denoising, the level is normalised (disable with --no-normalize): a gain is applied so
the speech level (90th percentile of 20 ms RMS) reaches --target-dbfs, limited by --max-gain-db,
and a soft limiter keeps rare loud clicks from clipping. Very quiet clips are only amplified
up to that cap.

INSTALL (pick what you need; Python 3.9+)
-----------------------------------------
    pip install numpy scipy                   # always required
    pip install pyrnnoise                     # for --engine rnnoise
    pip install deepfilternet torch torchaudio    # for --engine deepfilternet
On an Ubuntu box with an NVIDIA GPU, install a CUDA build of torch first if you want the GPU
(see https://pytorch.org/get-started/locally/). deepfilternet 0.5.6 imports a torchaudio module
that newer torchaudio releases removed; this script installs a small shim for that, so the
latest torch/torchaudio work.

USAGE
-----
    ./clean_audio.py hello-ab-test2.wav                         # -> hello-ab-test2_deepfilternet.wav
    ./clean_audio.py hello-ab-test2.wav --engine both           # compare the two
    ./clean_audio.py "…/sound run/episode_0007" --engine rnnoise
    ./clean_audio.py "…/sound run"                              # every episode under a task dir
    ./clean_audio.py in.wav -o out.wav --wet 0.8 --target-dbfs -22

An input can be a WAV file, an episode directory (its audios/audio.wav is used), or any
directory that contains such episodes (searched recursively for audios/audio.wav).
"""

import argparse
import math
import sys
import time
import types
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly

ENGINE_SR = 48000          # both networks run at 48 kHz
RNNOISE_FRAME = 480        # 10 ms at 48 kHz
RNNOISE_DELAY = 2 * RNNOISE_FRAME   # measured: output lags input by 959-960 samples (20 ms)
ENGINES = ("rnnoise", "deepfilternet")


# ------------------------------------------------------------------ audio I/O
def read_wav(path):
    """Return (mono float32 samples in [-1, 1], sample rate)."""
    rate, data = wavfile.read(str(path))
    if data.dtype == np.int16:
        x = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        x = data.astype(np.float32) / 2147483648.0
    elif data.dtype == np.uint8:
        x = (data.astype(np.float32) - 128.0) / 128.0
    else:
        x = data.astype(np.float32)
    if x.ndim == 2:
        x = x.mean(axis=1)
    return x, rate


def write_wav(path, x, rate):
    pcm = np.clip(np.round(x * 32768.0), -32768, 32767).astype("<i2")
    wavfile.write(str(path), rate, pcm)


def resample(x, rate_in, rate_out):
    if rate_in == rate_out:
        return x.astype(np.float32, copy=False)
    g = math.gcd(rate_in, rate_out)
    return resample_poly(x, rate_out // g, rate_in // g).astype(np.float32)


def dbfs(value):
    return 20.0 * math.log10(max(float(value), 1e-9))


def speech_level_dbfs(x, rate):
    """Loudness proxy: 90th percentile of the 20 ms block RMS (ignores silent gaps)."""
    n = int(0.02 * rate)
    blocks = x[: len(x) // n * n].reshape(-1, n)
    rms = np.sqrt((blocks.astype(np.float64) ** 2).mean(axis=1))
    return dbfs(np.percentile(rms, 90)) if rms.size else -120.0


# ------------------------------------------------------------------ engines
def enhance_rnnoise(x48):
    """RNNoise on 48 kHz float audio in [-1, 1]; returns float32 of the same length."""
    try:
        # The low-level ctypes wrapper is used on purpose: pyrnnoise's high-level RNNoise class
        # depends on audiolab's resampler graph API, which changes between audiolab releases.
        from pyrnnoise import rnnoise
    except ImportError:
        sys.exit("The rnnoise engine needs pyrnnoise:  pip install pyrnnoise")

    n = len(x48)
    pcm = np.clip(np.round(x48 * 32768.0), -32768, 32767).astype(np.int16)
    # RNNoise delays its output by RNNOISE_DELAY samples. Padding the input flushes the tail
    # and the first RNNOISE_DELAY output samples are dropped, keeping audio in sync with video.
    padded = np.zeros((n // RNNOISE_FRAME + 3) * RNNOISE_FRAME, dtype=np.int16)
    padded[:n] = pcm

    state = rnnoise.create()
    try:
        out = np.empty_like(padded)
        for i in range(0, len(padded), RNNOISE_FRAME):
            frame, _prob = rnnoise.process_mono_frame(state, padded[i:i + RNNOISE_FRAME])
            out[i:i + RNNOISE_FRAME] = frame
    finally:
        rnnoise.destroy(state)
    y = out[RNNOISE_DELAY:RNNOISE_DELAY + n].astype(np.float32) / 32768.0
    return y


_DF_CACHE = {}


def enhance_deepfilternet(x48, atten_lim_db=None):
    """DeepFilterNet3 on 48 kHz float audio; returns float32 of the same length."""
    _install_torchaudio_shim()
    try:
        import torch
        from df.enhance import enhance, init_df
    except ImportError:
        sys.exit("The deepfilternet engine needs:  pip install deepfilternet torch torchaudio")

    if "model" not in _DF_CACHE:
        # log_file=None: init_df would otherwise drop an enhance.log in the current directory.
        _DF_CACHE["model"] = init_df(log_file=None, log_level="WARNING")
    model, df_state, _ = _DF_CACHE["model"]
    if df_state.sr() != ENGINE_SR:
        sys.exit(f"Unexpected DeepFilterNet sample rate {df_state.sr()} (expected {ENGINE_SR}).")

    with torch.no_grad():
        audio = torch.from_numpy(x48).unsqueeze(0)
        y = enhance(model, df_state, audio, atten_lim_db=atten_lim_db)
    y = y.squeeze(0).cpu().numpy().astype(np.float32)
    if len(y) < len(x48):
        y = np.pad(y, (0, len(x48) - len(y)))
    return y[:len(x48)]


def _install_torchaudio_shim():
    """deepfilternet 0.5.x does `from torchaudio.backend.common import AudioMetaData` at import
    time, a module torchaudio removed in 2.1+. Only the (unused) file-loading helpers need it,
    so a stub is enough to make `import df` work with current torchaudio."""
    try:
        from torchaudio.backend.common import AudioMetaData  # noqa: F401
        return
    except ImportError:
        pass
    try:
        import torchaudio  # noqa: F401
    except ImportError:
        return  # the caller reports the missing dependency
    backend = types.ModuleType("torchaudio.backend")
    common = types.ModuleType("torchaudio.backend.common")

    class AudioMetaData:  # placeholder for the removed class
        pass

    common.AudioMetaData = AudioMetaData
    backend.common = common
    sys.modules["torchaudio.backend"] = backend
    sys.modules["torchaudio.backend.common"] = common


# ------------------------------------------------------------------ pipeline
def soft_limit(x, knee=0.7):
    """Smoothly squeeze samples above `knee` towards (never reaching) full scale."""
    a = np.abs(x)
    over = a > knee
    y = x.copy()
    y[over] = np.sign(x[over]) * (knee + (1.0 - knee) * np.tanh((a[over] - knee) / (1.0 - knee)))
    return y


def normalize(x, rate, target_dbfs, max_gain_db):
    """Scale so the speech level hits `target_dbfs` (gain capped at `max_gain_db`).

    A soft limiter catches the occasional click that the gain pushes past full scale, so a
    single spike does not hold back the gain for the whole clip.
    """
    if not x.size or not x.any():
        return x, 0.0
    gain_db = min(target_dbfs - speech_level_dbfs(x, rate), max_gain_db)
    return soft_limit(x * (10.0 ** (gain_db / 20.0))), gain_db


def clean_file(src, dst, engine, args):
    x, rate = read_wav(src)
    t0 = time.time()
    x48 = resample(x, rate, ENGINE_SR)
    if engine == "rnnoise":
        y48 = enhance_rnnoise(x48)
    else:
        y48 = enhance_deepfilternet(x48, atten_lim_db=args.atten_lim_db)
    if args.wet < 1.0:
        y48 = args.wet * y48 + (1.0 - args.wet) * x48
    y = resample(y48, ENGINE_SR, rate)
    y = np.pad(y, (0, max(0, len(x) - len(y))))[:len(x)]   # exactly the input length

    gain_db = 0.0
    if not args.no_normalize:
        y, gain_db = normalize(y, rate, args.target_dbfs, args.max_gain_db)
    write_wav(dst, y, rate)

    print(f"  [{engine}] {dst}")
    print(f"      {len(x) / rate:.1f} s | speech level {speech_level_dbfs(x, rate):.1f} -> "
          f"{speech_level_dbfs(y, rate):.1f} dBFS | peak {dbfs(np.abs(x).max()):.1f} -> "
          f"{dbfs(np.abs(y).max()):.1f} dBFS | gain {gain_db:+.1f} dB | {time.time() - t0:.1f} s")


def find_inputs(paths):
    files = []
    for p in map(Path, paths):
        if p.is_file():
            files.append(p)
        elif (p / "audios" / "audio.wav").is_file():
            files.append(p / "audios" / "audio.wav")
        elif p.is_dir():
            found = sorted(p.rglob("audios/audio.wav"))
            if not found:
                sys.exit(f"No audios/audio.wav found under {p}")
            files.extend(found)
        else:
            sys.exit(f"Not found: {p}")
    return files


def output_path(src, engine, args):
    if args.output:
        return Path(args.output)
    stem = src.stem
    if args.output_dir and src.parent.name == "audios":
        stem = f"{src.parent.parent.name}_{stem}"   # episode_0006_audio: keeps episodes apart
    directory = Path(args.output_dir) if args.output_dir else src.parent
    return directory / f"{stem}{args.suffix.format(engine=engine)}{src.suffix}"


def parse_args():
    p = argparse.ArgumentParser(
        description="Denoise recorded G1 microphone audio (motor noise) and normalise its level.",
        epilog="See the top of this file for installation and the details of each engine.")
    p.add_argument("inputs", nargs="+", metavar="INPUT",
                   help="WAV file, episode directory, or a directory of episodes")
    p.add_argument("-e", "--engine", choices=ENGINES + ("both",), default="deepfilternet",
                   help="denoiser (default: %(default)s); 'both' writes one file per engine")
    p.add_argument("-o", "--output", help="output WAV path (one input and one engine only)")
    p.add_argument("--output-dir", help="write outputs here instead of next to each input")
    p.add_argument("--suffix", default="_{engine}",
                   help="appended to the input name, {engine} is replaced (default: %(default)s)")
    p.add_argument("--wet", type=float, default=1.0, metavar="0..1",
                   help="mix of enhanced (1.0) vs original (0.0) audio; lower keeps more of the "
                        "room sound and the noise (default: %(default)s)")
    p.add_argument("--atten-lim-db", type=float, default=None, metavar="DB",
                   help="deepfilternet only: cap the noise reduction (e.g. 12) for a more natural sound")
    p.add_argument("--no-normalize", action="store_true", help="skip the loudness normalisation")
    p.add_argument("--target-dbfs", type=float, default=-24.0,
                   help="speech level to normalise to (default: %(default)s dBFS)")
    p.add_argument("--max-gain-db", type=float, default=20.0,
                   help="largest gain normalisation may apply (default: %(default)s dB)")
    args = p.parse_args()
    if not 0.0 <= args.wet <= 1.0:
        p.error("--wet must be between 0 and 1")
    return args


def main():
    args = parse_args()
    engines = list(ENGINES) if args.engine == "both" else [args.engine]
    files = find_inputs(args.inputs)
    if args.output and (len(files) > 1 or len(engines) > 1):
        sys.exit("-o/--output needs exactly one input file and one engine; use --output-dir instead.")
    jobs = [(src, engine, output_path(src, engine, args)) for src in files for engine in engines]
    outputs = [dst for _, _, dst in jobs]
    if len(set(outputs)) != len(outputs):
        sys.exit("Several inputs would write the same output file; drop --output-dir or use "
                 "inputs with different names.")
    if args.output_dir:
        Path(args.output_dir).mkdir(parents=True, exist_ok=True)

    last = None
    for src, engine, dst in jobs:
        if src != last:
            print(src)
            last = src
        clean_file(src, dst, engine, args)


if __name__ == "__main__":
    main()
