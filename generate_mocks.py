from PIL import Image, ImageDraw, ImageFont
import os

def create_mock(filename, text, color):
    img = Image.new('RGB', (1920, 1080), color=color)
    d = ImageDraw.Draw(img)
    # Draw simple "UI elements"
    d.rectangle([100, 100, 400, 200], fill="white", outline="black")
    d.text((120, 120), f"Button: {text}", fill="black")
    
    d.rectangle([500, 100, 1800, 900], fill="white", outline="black")
    d.text((520, 120), f"Main Content: {text}", fill="black")
    
    # Save
    path = os.path.join("assets", "mock", filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print(f"Created {path}")

create_mock("screen_login.png", "Login Page", "lightblue")
create_mock("screen_dashboard.png", "Dashboard", "lightgray")
create_mock("screen_settings.png", "Settings", "lightgreen")
