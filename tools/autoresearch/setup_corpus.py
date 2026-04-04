"""Copy test audio files to the autoresearch corpus directory."""

import shutil
from pathlib import Path

from config import CORPUS_DIR

DOWNLOADS = Path(r"C:\Users\jagv1\Downloads")

FILES = {
    "A_Poncho_Mensaje.wav": "poncho_mensaje.wav",
    "A_Poncho_Mensaje_ground_truth.txt": "poncho_mensaje.txt",
}


def setup():
    CORPUS_DIR.mkdir(exist_ok=True)
    for src_name, dst_name in FILES.items():
        src = DOWNLOADS / src_name
        dst = CORPUS_DIR / dst_name
        if not src.exists():
            print(f"  SKIP {src_name}: not found in Downloads")
            continue
        shutil.copy2(src, dst)
        print(f"  Copied {src_name} -> {dst_name}")


if __name__ == "__main__":
    setup()
