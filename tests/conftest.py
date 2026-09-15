"""pytest-Setup: main.py liegt im Repo-Root, daher Pfad ergänzen."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
