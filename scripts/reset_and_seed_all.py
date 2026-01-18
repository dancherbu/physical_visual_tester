import requests
import sys
import subprocess
import os

# Force UTF-8
sys.stdout.reconfigure(encoding='utf-8')

QDRANT_URL = "http://localhost:6333"
COLLECTION_NAME = "pvt_memory"

SCRIPTS_TO_RUN = [
    "seed_expert_memory.py",
    "seed_common_ui.py",
    "seed_file_explorer.py",
    "seed_text_editor.py",
    "seed_browser_knowledge.py"
]

def delete_collection():
    print(f"🗑️ Deleting Collection: {COLLECTION_NAME}...")
    try:
        resp = requests.delete(f"{QDRANT_URL}/collections/{COLLECTION_NAME}")
        if resp.status_code == 200:
            print("   ✅ Deleted.")
        else:
            print(f"   ⚠️ Delete failed (maybe didn't exist): {resp.text}")
    except Exception as e:
        print(f"   ❌ Network Error: {e}")

def create_collection():
    print(f"🆕 Creating Collection: {COLLECTION_NAME}...")
    # Using default config (Cosine distance usually)
    payload = {
        "vectors": {
            "size": 768, # Nomic-embed-text size
            "distance": "Cosine"
        }
    }
    try:
        resp = requests.put(f"{QDRANT_URL}/collections/{COLLECTION_NAME}", json=payload)
        if resp.status_code == 200:
             print("   ✅ Created.")
        else:
             print(f"   ❌ Create Failed: {resp.text}")
    except Exception as e:
        print(f"   ❌ Network Error: {e}")

def run_script(script_name):
    print(f"\n▶️ Running {script_name}...")
    script_path = os.path.join(os.path.dirname(__file__), script_name)
    try:
        # Use subprocess to call the other python scripts
        subprocess.run(["python", "-u", script_path], check=True)
    except subprocess.CalledProcessError as e:
        print(f"   ❌ Error running {script_name}: {e}")

def main():
    print("🚀 STARTING FULL MEMORY RESET & SEEDING SEQUENCE")
    print("================================================")
    
    # 1. Reset DB
    delete_collection()
    create_collection()
    
    # 2. Seed All
    for script in SCRIPTS_TO_RUN:
        run_script(script)
        
    print("\n✅ SEQUENCE COMPLETE.")

if __name__ == "__main__":
    main()
