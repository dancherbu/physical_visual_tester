from PIL import Image, ImageDraw, ImageFont
import os

def create_mock(filename, title, color, elements):
    img = Image.new('RGB', (1920, 1080), color=color)
    d = ImageDraw.Draw(img)
    
    # Header
    d.rectangle([0, 0, 1920, 80], fill="#b7472a", outline=None)
    d.text((50, 20), f"PowerPoint - {title}", fill="white")

    # Draw Elements
    for (text, rect) in elements:
        x, y, w, h = rect
        d.rectangle([x, y, x+w, y+h], fill="white", outline="black")
        d.text((x+20, y+20), text, fill="black")
    
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
    ("File", (20, 90, 80, 40)),
    ("Home", (120, 90, 80, 40)),
    ("Insert", (220, 90, 80, 40)),
    ("Design", (320, 90, 80, 40)),
    # Slide Content
    ("Click to add title", (400, 300, 1120, 200)),
    ("Click to add subtitle", (400, 600, 1120, 150))
])

# PPT Editor (Insert Tab)
create_mock("ppt_editor_insert.png", "Presentation1", "#e0e0e0", [
    ("File", (20, 90, 80, 40)),
    ("Home", (120, 90, 80, 40)),
    ("Insert", (220, 90, 80, 40)), # Active?
    ("Design", (320, 90, 80, 40)),
    # Ribbon Items
    ("Pictures", (50, 150, 100, 80)),
    ("Shapes", (170, 150, 100, 80)),
    ("Chart", (290, 150, 100, 80)),
    # Slide Content same
    ("Slide Preview", (400, 300, 1120, 200)), 
])
