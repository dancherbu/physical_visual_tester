import os
import sys
import json
import requests
import datetime
import time

# Force UTF-8
sys.stdout.reconfigure(encoding='utf-8')

OLLAMA_URL = "http://localhost:11434"
QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "pvt_memory"
EMBED_MODEL = "nomic-embed-text"

KNOWLEDGE_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "filesystem_sql_knowledge.json"))

def get_embedding(text):
    payload = { "model": EMBED_MODEL, "prompt": text }
    try:
        resp = requests.post(f"{OLLAMA_URL}/api/embeddings", json=payload)
        return resp.json().get('embedding')
    except:
        return None

def save_to_qdrant(embedding, payload):
    url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points"
    point_id = int(time.time() * 1000) + int(hash(json.dumps(payload)) % 10000)
    body = { "points": [ { "id": point_id, "vector": embedding, "payload": payload } ] }
    try:
        requests.put(url, json=body)
        return True
    except:
        return False

def main():
    print("📊 Seeding SQL FileSystem Knowledge...")
    if not os.path.exists(KNOWLEDGE_FILE):
        print("❌ File not found.")
        return

    with open(KNOWLEDGE_FILE, 'r', encoding='utf-8') as f:
        data = json.load(f)

    for item in data:
        description = item['description']
        actions = item['actions']
        print(f"Set: {description}")
        for act in actions:
            goal = act['goal']
            # Prompt context: "Goal: <goal>. Screen: System Index."
            prompt = f"Goal: {goal}. Screen: System Index File System Database."
            vector = get_embedding(prompt)
            if vector:
                payload = {
                    "goal": goal,
                    "action": act['action'],
                    "description": description,
                    "fact": act['fact'],
                    "source": "sql_system_index"
                }
                save_to_qdrant(vector, payload)
                print(f"   Indexed: {goal}")
    
    print("✅ Done.")

if __name__ == "__main__":
    main()
