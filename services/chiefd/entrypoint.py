"""Executable entry point used by PyInstaller for the desktop sidecar."""

from services.chiefd.server import main


if __name__ == "__main__":
    main()
