import os
import sys
import glob
import base64
import json
import requests
import datetime
import time

# Force UTF-8 for Windows Console
sys.stdout.reconfigure(encoding='utf-8')

# Configuration
OLLAMA_URL = "http://localhost:11434"
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "pvt_memory"
MOCK_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../assets/mock"))

# Models
EMBED_MODEL = "nomic-embed-text"
VISION_MODELS = ["moondream", "llava", "llama3.2-vision", "llama3.2"] 

def get_available_models():
    try:
        resp = requests.get(f"{OLLAMA_URL}/api/tags")
        if resp.status_code == 200:
            models = [m['name'] for m in resp.json()['models']]
            return models
    except Exception as e:
        print(f"❌ Could not connect to Ollama: {e}")
        return []
    return []

def select_vision_model(available):
    for v in VISION_MODELS:
        # Match "llava:latest" or just "llava"
        match = next((m for m in available if m.startswith(v)), None)
        if match:
            return match
    return None

def analyze_image(model, image_path):
    print(f"   Using model: {model}")
    with open(image_path, "rb") as f:
        img_bytes = f.read()
        base64_img = base64.b64encode(img_bytes).decode('utf-8')

    prompt = """
    Analyze this UI screen screenshot.
    
    Part 1: GLOBAL CONTEXT (Prerequisites)
    - Identify the Window Date/Time if visible.
    - Identify the Active Application (Window Title).
    - Identify the URL if it's a browser.
    - Identify any specific state (e.g. "Login Page", "Empty File", "Dashboard").
    
    Part 2: ACTIONABLE ELEMENTS
    - List every clickable button, link, or input field.
    - For each, infer the USER GOAL (e.g. "Log In", "Open Settings", "Type Text").
    - Infer the ACTION (click/type) and TARGET TEXT.
    
    OUTPUT JSON FORMAT ONLY:
    {
      "description": "A detailed description of the screen context...",
      "prerequisites": ["App: Notepad", "File: Empty"],
      "actions": [
        {
          "goal": "Save the file",
          "action": {"type": "click", "target_text": "File > Save"},
          "fact": "Opens the save dialog"
        }
      ]
    }
    """

    payload = {
        "model": model,
        "prompt": prompt,
        "images": [base64_img],
        "stream": False,
        # "format": "json" # Force JSON mode if supported
    }

    try:
        resp = requests.post(f"{OLLAMA_URL}/api/generate", json=payload)
        if resp.status_code == 200:
            return resp.json()['response']
        else:
            print(f"   ❌ Ollama Error: {resp.text}")
    except Exception as e:
        print(f"   ❌ Network Error: {e}")
    return None

def get_embedding(text):
    payload = {
        "model": EMBED_MODEL,
        "prompt": text
    }
    try:
        resp = requests.post(f"{OLLAMA_URL}/api/embeddings", json=payload)
        if resp.status_code == 200:
            return resp.json()['embedding']
    except Exception as e:
        print(f"   ❌ Embedding Error: {e}")
    return None

def save_to_qdrant(embedding, payload):
    url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points"
    
    point_id = int(time.time() * 1000) # Simple ID
    
    body = {
        "points": [
            {
                "id": point_id,
                "vector": embedding,
                "payload": payload
            }
        ]
    }
    
    try:
        resp = requests.put(url, json=body)
        if resp.status_code >= 300:
            print(f"   ❌ Qdrant Error: {resp.text}")
            return False
        return True
    except Exception as e:
        print(f"   ❌ Qdrant Network Error: {e}")
        return False

def extract_json(text):
    try:
        start = text.find('{')
        end = text.rfind('}')
        if start != -1 and end != -1:
            return json.loads(text[start:end+1])
    except:
        pass
    return {}

def main():
    print("🚀 Starting Offline Pre-Training (Python Script)")
    print(f"📂 Mock Directory: {MOCK_DIR}")
    
    # 1. Setup Models
    available = get_available_models()
    print(f"ℹ️  Available Models: {available}")
    
    vision_model = select_vision_model(available)
    if not vision_model:
        print("❌ No suitable vision model found (llava, moondream, llama3.2-vision). Please `ollama pull llava`.")
        return

    # Check embedding model
    if not any(m.startswith(EMBED_MODEL) for m in available):
         print(f"⚠️  Embedding model '{EMBED_MODEL}' not found. Attempting to pull...")
         requests.post(f"{OLLAMA_URL}/api/pull", json={"name": EMBED_MODEL})

    # 2. Iterate Images
    image_paths = glob.glob(os.path.join(MOCK_DIR, "*.png"))
    print(f"📸 Found {len(image_paths)} images.")
    
    total_learned = 0
    
    for path in image_paths:
        filename = os.path.basename(path)
        print(f"\nProcessing {filename}...")
        
        # Analyze
        json_str = analyze_image(vision_model, path)
        if not json_str:
            continue
            
        data = extract_json(json_str)
        if not data:
            print(f"   ⚠️ Failed to parse JSON from Ollama. response: {json_str[:100]}...")
            continue
            
        description = data.get('description', 'Unknown Screen')
        prerequisites = data.get('prerequisites', [])
        actions = data.get('actions', [])
        
        print(f"   📝 Found {len(actions)} actions. Context: {prerequisites}")
        
        for action_item in actions:
            goal = action_item.get('goal')
            action = action_item.get('action')
            fact = action_item.get('fact', '')
            
            if goal and action:
                # Prepare Learning Payload
                full_description = f"{description}\nPrerequisites: {', '.join(prerequisites)}"
                prompt = f"Goal: {goal}. Screen: {full_description}. Prerequisites: {prerequisites}"
                
                # Embed
                vector = get_embedding(prompt)
                
                if vector:
                    # Save
                    payload = {
                        "goal": goal,
                        "action": action,
                        "description": full_description,
                        "prerequisites": prerequisites,
                        "fact": fact,
                        "timestamp": datetime.datetime.now().isoformat()
                    }
                    
                    if save_to_qdrant(vector, payload):
                         print(f"     ✅ Learned: {goal}")
                         total_learned += 1
                    
                    # Small delay to prevent rate limits or overwhelming
                    time.sleep(0.1)

    print(f"\n🎉 Training Complete! Total Skills Learned: {total_learned}")

if __name__ == "__main__":
    main()
