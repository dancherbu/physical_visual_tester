import requests
import json
import sys

# Force UTF-8
sys.stdout.reconfigure(encoding='utf-8')

def main():
    prompt = "Goal: Click Start. Screen: Windows 11 Desktop with Taskbar visible at the bottom.\nPrerequisites: . Prerequisites: []"
    # prompt = "Goal: Click Start. Screen: Windows 11 Desktop with Taskbar visible at the bottom. Prerequisites: "
    
    print(f"🔎 Querying: '{prompt}'")
    
    # 1. Embed
    resp = requests.post('http://localhost:11434/api/embeddings', json={
        "model": "nomic-embed-text",
        "prompt": prompt
    })
    vector = resp.json()['embedding']
    
    # 2. Search
    search_resp = requests.post('http://localhost:6333/collections/pvt_memory/points/search', json={
        "vector": vector,
        "limit": 3,
        "with_payload": True
    })
    
    results = search_resp.json()['result']
    for res in results:
        print(f"\nScore: {res['score']}")
        print(f"Goal: {res['payload']['goal']}")
        print(f"Action: {res['payload']['action']}")

if __name__ == "__main__":
    main()
