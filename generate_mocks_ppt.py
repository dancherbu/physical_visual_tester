from PIL import Image, ImageDraw, ImageFont
import os

def create_mock(filename, title, color, elements):
    img = Image.new('RGB', (1920, 1080), color=color)
    d = ImageDraw.Draw(img)
    
    # Try to load a larger font
    try:
        # Windows standard path
        font_large = ImageFont.truetype("arial.ttf", 40)
        font_header = ImageFont.truetype("arial.ttf", 60)
    except IOError:
        print("Arial font not found, using default (small!)")
        font_large = ImageFont.load_default()
        font_header = ImageFont.load_default()

    # Header
    d.rectangle([0, 0, 1920, 100], fill="#b7472a", outline=None)
    d.text((50, 20), f"PowerPoint - {title}", fill="white", font=font_header)

    # Draw Elements
    for (text, rect) in elements:
        x, y, w, h = rect
        d.rectangle([x, y, x+w, y+h], fill="white", outline="black", width=3)
        
        # Center text in rect
        text_bbox = d.textbbox((0, 0), text, font=font_large)
        text_w = text_bbox[2] - text_bbox[0]
        text_h = text_bbox[3] - text_bbox[1]
        
        tx = x + (w - text_w) / 2
        ty = y + (h - text_h) / 2
        
        d.text((tx, ty), text, fill="black", font=font_large)
    
    # Save
    path = os.path.join("assets", "mock", "powerpoint", filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print(f"Created {path}")

# PPT Home
create_mock("ppt_home.png", "Home", "#fdfdfd", [
    ("New Presentation", (100, 200, 300, 200)),
    ("Open Existing", (500, 200, 300, 200)),
    ("Recent Files", (100, 500, 800, 400)) 
])

# PPT Editor (Home Tab)
create_mock("ppt_editor_home.png", "Presentation1", "#e0e0e0", [
    ("File", (20, 110, 100, 50)),
    ("Home", (140, 110, 100, 50)),
    ("Insert", (260, 110, 100, 50)),
    ("Design", (380, 110, 100, 50)),
    # Slide Content
    ("Click to add title", (400, 300, 1120, 200)),
    ("Click to add subtitle", (400, 600, 1120, 150))
])

# PPT Editor (Insert Tab)
create_mock("ppt_editor_insert.png", "Presentation1", "#e0e0e0", [
    ("File", (20, 110, 100, 50)),
    ("Home", (140, 110, 100, 50)),
    ("Insert", (260, 110, 100, 50)), # Active
    ("Design", (380, 110, 100, 50)),
    # Ribbon Items
    ("Pictures", (50, 180, 150, 100)),
    ("Shapes", (220, 180, 150, 100)),
    ("Chart", (390, 180, 150, 100)),
    # Slide Content same
    ("Slide Preview", (400, 350, 1120, 200)), 
])
