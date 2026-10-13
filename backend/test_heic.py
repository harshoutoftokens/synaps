"""Ad-hoc check that pillow-heif can decode a HEIC: python test_heic.py /path/to/IMG.HEIC"""
import sys

if __name__ == "__main__":
    from PIL import Image
    import pillow_heif
    pillow_heif.register_heif_opener()
    path = sys.argv[1] if len(sys.argv) > 1 else '/storage/Vault/Harsh/Iphone/IMG_3130.HEIC'
    with Image.open(path) as img:
        img.thumbnail((1920, 1920), Image.LANCZOS)
    print("SUCCESS")
