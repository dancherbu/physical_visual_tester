import os
import sys
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
EMBED_MODEL = "nomic-embed-text"

KNOWLEDGE_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "common_ui_elements.json"))

def get_embedding(text):
    payload = {
        "model": EMBED_MODEL,
        "prompt": text
    }
    try:
        resp = requests.post(f"{OLLAMA_URL}/api/embeddings", json=payload)
        if resp.status_code == 200:
            return resp.json()['embedding']
        else:
             # Try pulling model if missing
             if resp.status_code == 404:
                 print(f"   ⚠️ Model '{EMBED_MODEL}' missing. Pulling...")
                 requests.post(f"{OLLAMA_URL}/api/pull", json={"name": EMBED_MODEL})
                 time.sleep(2)
                 return get_embedding(text) # Retry once
    except Exception as e:
        print(f"   ❌ Network Error (Ollama): {e}")
    return None

def save_to_qdrant(embedding, payload):
    url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points"
    point_id = int(time.time() * 1000) + int(hash(json.dumps(payload)) % 10000) # Unique ID
    
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
        print(f"   ❌ Network Error (Qdrant): {e}")
        return False

def main():
    print("🧠 Starting Common UI Element Seeding...")
    print(f"📂 Reading from: {KNOWLEDGE_FILE}")
    
    if not os.path.exists(KNOWLEDGE_FILE):
        print("❌ Common UI knowledge file not found!")
        return

    with open(KNOWLEDGE_FILE, 'r', encoding='utf-8') as f:
        knowledge_base = json.load(f)

    print(f"ℹ️  Found {len(knowledge_base)} generic contexts. Embedding and saving...")

    total_added = 0
    
    for scenario in knowledge_base:
        description = scenario.get('description', '')
        prerequisites = scenario.get('prerequisites', [])
        actions = scenario.get('actions', [])
        
        full_context = f"{description}\nPrerequisites: {', '.join(prerequisites)}"
        print(f"\nProcessing Context: {description[:50]}...")

        for item in actions:
            goal = item.get('goal')
            action = item.get('action')
            fact = item.get('fact', '')
            
            if goal and action:
                # We embed a generic prompt. 
                # Ideally, if the robot sees "OK", it might not know the context is a "Dialog".
                # BUT, if the robot is "Thinking" about "Confirming", this memory will trigger.
                
                # Embedding Strat: Generic Prompt
                # "Goal: <Goal>. Screen: <Description>"
                prompt = f"Goal: {goal}. Screen: {full_context}. Action: Click {action['target_text']}"
                
                print(f"   🔹 Embedding UI Element: '{action['target_text']}' ({goal})...", end='')
                vector = get_embedding(prompt)
                
                if vector:
                    payload = {
                        "goal": goal,
                        "action": action,
                        "description": full_context,
                        "prerequisites": prerequisites,
                        "fact": fact,
                        "timestamp": datetime.datetime.now().isoformat(),
                        "source": "common_ui_knowledge" 
                    }
                    
                    if save_to_qdrant(vector, payload):
                        print(" ✅ Saved.")
                        total_added += 1
                    else:
                        print(" ❌ Failed to Save.")
                else:
                    print(" ❌ Embedding Failed.")
                
                # Tiny delay
                time.sleep(0.05)

    print(f"\n🎉 UI Seeding Complete! Added {total_added} generic UI elements to Memory.")

if __name__ == "__main__":
    main()
