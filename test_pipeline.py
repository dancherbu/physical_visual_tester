import requests
import json

# Test embedding
print('Testing Ollama embedding...')
embed_resp = requests.post('http://localhost:11434/api/embeddings', json={
    'model': 'nomic-embed-text',
    'prompt': 'Test button for saving files'
})
embed_data = embed_resp.json()
embedding = embed_data.get('embedding', [])
print(f'Embedding dim: {len(embedding)}')

if len(embedding) == 768:
    print('OK: Embedding dimension correct!')
    
    # Test saving to Qdrant
    print('Testing Qdrant save...')
    save_resp = requests.put('http://localhost:6333/collections/pvt_memory/points', json={
        'points': [{
            'id': 999999999,  # Test ID
            'vector': embedding,
            'payload': {
                'goal': 'Test Save',
                'action': {'type': 'click', 'target_text': 'TestButton'},
                'fact': 'This is a test entry'
            }
        }]
    })
    print(f'Save status: {save_resp.status_code}')
    print(f'Save response: {save_resp.json()}')
    
    # Test searching
    print('Testing Qdrant search...')
    search_resp = requests.post('http://localhost:6333/collections/pvt_memory/points/search', json={
        'vector': embedding,
        'limit': 5,
        'with_payload': True
    })
    search_data = search_resp.json()
    print(f'Search status: {search_resp.status_code}')
    results = search_data.get('result', [])
    print(f'Found {len(results)} results:')
    for r in results:
        target = r.get('payload',{}).get('action',{}).get('target_text', 'N/A')
        print(f"  - score={r['score']:.4f}, target={target}")
        
    # Check collection stats
    print('\nCollection stats:')
    stats_resp = requests.get('http://localhost:6333/collections/pvt_memory')
    stats = stats_resp.json()
    result = stats.get('result', {})
    print(f"  points_count: {result.get('points_count', 'N/A')}")
    print(f"  indexed_vectors_count: {result.get('indexed_vectors_count', 'N/A')}")
    print(f"  status: {result.get('status', 'N/A')}")
else:
    print(f'ERROR: Unexpected embedding dimension: {len(embedding)}')
