import os
import sys
import json
import requests
import datetime
import time

# Force UTF-8
sys.stdout.reconfigure(encoding='utf-8')

# Configuration
OLLAMA_URL = "http://localhost:11434"
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "pvt_memory"
EMBED_MODEL = "nomic-embed-text"

KNOWLEDGE_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "windows_shortcuts_knowledge.json"))

def get_embedding(text):
    payload = { "model": EMBED_MODEL, "prompt": text }
    try:
        resp = requests.post(f"{OLLAMA_URL}/api/embeddings", json=payload)
        if resp.status_code == 200:
            return resp.json()['embedding']
    except Exception as e:
        print(f"   ❌ Embedding Error: {e}")
    return None

def save_to_qdrant(embedding, payload):
    url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points"
    point_id = int(time.time() * 1000) + int(hash(json.dumps(payload)) % 10000)
    body = {
        "points": [ { "id": point_id, "vector": embedding, "payload": payload } ]
    }
    try:
        requests.put(url, json=body)
        return True
    except:
        return False

def main():
    print("⌨️  Starting Shortcuts Knowledge Seeding...")
    if not os.path.exists(KNOWLEDGE_FILE):
        print("❌ Knowledge file not found!")
        return

    with open(KNOWLEDGE_FILE, 'r', encoding='utf-8') as f:
        knowledge_base = json.load(f)

    total_added = 0
    for scenario in knowledge_base:
        description = scenario.get('description', '')
        prerequisites = scenario.get('prerequisites', [])
        actions = scenario.get('actions', [])
        
        full_context = f"{description}\nPrerequisites: {', '.join(prerequisites)}"
        print(f"\nProcessing Context: {description}...")

        for item in actions:
            goal = item.get('goal')
            action = item.get('action')
            fact = item.get('fact', '')
            
            if goal and action:
                # Prompt: "Goal: Open Run Dialog. Screen: Windows Global keybinds. Action: Press Win+R"
                action_desc = f"Press {action['target_text']}" if 'keyboard' in action['type'] else f"Click {action['target_text']}"
                prompt = f"Goal: {goal}. Screen: {full_context}. Action: {action_desc}"
                
                print(f"   🔹 Embedding Shortcut: '{goal}' ({action['target_text']})...", end='')
                vector = get_embedding(prompt)
                
                if vector:
                    payload = {
                        "goal": goal,
                        "action": action,
                        "description": full_context,
                        "prerequisites": prerequisites,
                        "fact": fact,
                        "timestamp": datetime.datetime.now().isoformat(),
                        "source": "windows_shortcuts" 
                    }
                    if save_to_qdrant(vector, payload):
                        print(" ✅ Saved.")
                        total_added += 1
                    else:
                        print(" ❌ Failed.")
                else:
                    print(" ❌ Embed Failed.")
                time.sleep(0.05)

    print(f"\n🎉 Shortcuts Seeding Complete! Added {total_added} skills.")

if __name__ == "__main__":
    main()
