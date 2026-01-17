import os
from PIL import Image, ImageDraw, ImageFont

def create_robot_icon(size):
    # Background
    img = Image.new('RGB', (size, size), color='#2196F3')
    d = ImageDraw.Draw(img)
    
    # Robot Head
    head_padding = size // 5
    head_rect = [head_padding, head_padding, size - head_padding, size - head_padding]
    d.rectangle(head_rect, fill='#E0E0E0', outline='#FFFFFF', width=size//40)
    
    # Eyes
    eye_radius = size // 12
    eye_y = size // 2.5
    d.ellipse([size//3 - eye_radius, eye_y - eye_radius, size//3 + eye_radius, eye_y + eye_radius], fill='#FF5722') # Left
    d.ellipse([size*2//3 - eye_radius, eye_y - eye_radius, size*2//3 + eye_radius, eye_y + eye_radius], fill='#FF5722') # Right
    
    # Antenna
    d.line([size//2, head_padding, size//2, head_padding//2], fill='#FFFFFF', width=size//30)
    d.ellipse([size//2 - size//20, head_padding//4 - size//20, size//2 + size//20, head_padding//4 + size//20], fill='#FF0000')

    return img

def main():
    base_dir = r"c:\Users\danbo\Documents\My Projects\physical_visual_tester\android\app\src\main\res"
    
    # Map map folders to sizes
    sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    
    if not os.path.exists(base_dir):
        print(f"Error: Directory {base_dir} not found.")
        return

    for folder, size in sizes.items():
        path = os.path.join(base_dir, folder)
        os.makedirs(path, exist_ok=True)
        
        icon = create_robot_icon(size)
        icon.save(os.path.join(path, "ic_launcher.png"))
        print(f"Saved {size}x{size} icon to {folder}")

if __name__ == "__main__":
    try:
        main()
    except ImportError:
        print("Pillow not installed. Installing...")
        os.system("pip install Pillow")
        main()
