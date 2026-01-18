import requests
import json
import sys

# Force UTF-8 for Windows Console
sys.stdout.reconfigure(encoding='utf-8')

QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "pvt_memory"
OLLAMA_URL = "http://localhost:11434"
EMBED_MODEL = "nomic-embed-text"

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

def main():
    print(f"🔍 Verifying Qdrant Collection: {COLLECTION_NAME}")
    
    # 1. Check Collection Info
    try:
        resp = requests.get(f"{QDRANT_URL}/collections/{COLLECTION_NAME}")
        if resp.status_code != 200:
            print(f"❌ Collection not found or error: {resp.text}")
            return
        
        info = resp.json()
        count = info['result']['points_count']
        print(f"✅ Collection exists. Total Points: {count}")
        
    except Exception as e:
        print(f"❌ Connection Error: {e}")
        return

    # 2. Scroll/List some points
    print("\n📜 Sampling recent memories:")
    try:
        # Scroll API
        url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points/scroll"
        resp = requests.post(url, json={"limit": 5, "with_payload": True})
        points = resp.json()['result']['points']
        
        for p in points:
            payload = p['payload']
            goal = payload.get('goal', 'N/A')
            source = payload.get('source', 'Unknown')
            print(f"   - [{source}] Goal: {goal}")
            
    except Exception as e:
        print(f"❌ Scroll Error: {e}")

    # 3. Test Search
    test_query = "Goal: Open Quick Access"
    print(f"\n🧪 Test Search Query: '{test_query}'")
    
    vector = get_embedding(test_query)
    if vector:
        search_url = f"{QDRANT_URL}/collections/{COLLECTION_NAME}/points/search"
        resp = requests.post(search_url, json={
            "vector": vector,
            "limit": 3,
            "with_payload": True
        })
        
        results = resp.json()['result']
        for res in results:
            score = res['score']
            goal = res['payload'].get('goal')
            print(f"   ⭐ Score: {score:.4f} -> {goal}")
    else:
        print("❌ Failed to generate test embedding.")

if __name__ == "__main__":
    main()
