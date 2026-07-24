import subprocess
import json
from pathlib import Path


def validate_image(image_path: Path) -> bool:
    """Run the file command to verify the path contains a valid image."""
    result = subprocess.run(
        ["file", "-b", str(image_path)], capture_output=True, text=True
    )
    fileformat = result.stdout.strip().split()[0]
    return fileformat, "image data" in result.stdout.lower()



def print_summary(metadata: dict, dest: str) -> None:
    """Print the matched image metadata in a structured format for the agent to consume."""
    image_fileformat, is_valid_image = validate_image(Path(dest))
    if not is_valid_image:
        print(f"Warning: The file at {dest} does not appear to be a valid image."
              "File must have been corrupted during decoding or writing.")
        return

    output = {
        "type": "image_metadata",
        "data": metadata
    }
    print("Raw JSON:", json.dumps(output))
    print(f"Matched {image_fileformat} image '{metadata.get('image-id')}' written to {dest}")