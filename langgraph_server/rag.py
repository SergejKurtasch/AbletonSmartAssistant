"""RAG search implementation (duplicates Swift RAGStore logic)"""
import json
import math
from pathlib import Path
from typing import List, Dict, Optional
from openai import OpenAI
# Support both relative imports (for LangGraph Studio) and absolute imports (for direct run)
try:
    from .config import (
        LIVE12_MANUAL_EMBEDDINGS, 
        ABLETON_VERSIONS_EMBEDDINGS, 
        RAG_TOP_K, 
        VERSION_CHECK_TOP_K,
        OPENAI_API_KEY
    )
except ImportError:
    from config import (
        LIVE12_MANUAL_EMBEDDINGS, 
        ABLETON_VERSIONS_EMBEDDINGS, 
        RAG_TOP_K, 
        VERSION_CHECK_TOP_K,
        OPENAI_API_KEY
    )

class Chunk:
    """Represents a documentation chunk"""
    def __init__(self, data: dict):
        self.id = data.get("id", "")
        self.content = data.get("content", "")
        self.edition = data.get("edition")
        self.embedding = data.get("embedding", [])
        self.metadata = data.get("metadata", {})

class RAGStore:
    """RAG store for retrieving documentation chunks"""
    
    def __init__(self):
        self.full_index: List[Chunk] = []
        self.versions_index: List[Chunk] = []
        self._load_indexes()
    
    def _load_indexes(self):
        """Load embedding indexes from JSON files"""
        # Load live12 manual chunks
        if LIVE12_MANUAL_EMBEDDINGS.exists():
            with open(LIVE12_MANUAL_EMBEDDINGS, 'r', encoding='utf-8') as f:
                chunks_data = json.load(f)
                self.full_index = [Chunk(chunk) for chunk in chunks_data]
                print(f"Loaded {len(self.full_index)} chunks from live12-manual-chunks-with-embeddings.json")
        else:
            print(f"Warning: {LIVE12_MANUAL_EMBEDDINGS} not found")
        
        # Load versions diff chunks
        if ABLETON_VERSIONS_EMBEDDINGS.exists():
            with open(ABLETON_VERSIONS_EMBEDDINGS, 'r', encoding='utf-8') as f:
                chunks_data = json.load(f)
                self.versions_index = [Chunk(chunk) for chunk in chunks_data]
                print(f"Loaded {len(self.versions_index)} chunks from Ableton-versions-diff-chunks-with-embeddings.json")
        else:
            print(f"Warning: {ABLETON_VERSIONS_EMBEDDINGS} not found")
    
    def _cosine_similarity(self, vec1: List[float], vec2: List[float]) -> float:
        """Calculate cosine similarity between two vectors"""
        if len(vec1) != len(vec2):
            return 0.0
        
        dot_product = sum(a * b for a, b in zip(vec1, vec2))
        magnitude1 = math.sqrt(sum(a * a for a in vec1))
        magnitude2 = math.sqrt(sum(a * a for a in vec2))
        
        if magnitude1 == 0 or magnitude2 == 0:
            return 0.0
        
        return dot_product / (magnitude1 * magnitude2)
    
    def _top_matches(self, chunks: List[Chunk], query_embedding: List[float], top_k: int) -> List[Chunk]:
        """Find top K matching chunks"""
        scored = [(chunk, self._cosine_similarity(query_embedding, chunk.embedding)) 
                  for chunk in chunks]
        scored.sort(key=lambda x: x[1], reverse=True)
        return [chunk for chunk, _ in scored[:top_k]]
    
    def retrieve(self, query_embedding: List[float], edition: str, top_k: int = RAG_TOP_K) -> Dict:
        """
        Retrieve relevant chunks for a query
        
        Returns:
            dict with 'full' (list of chunks) and 'versions' (list of version compatibility chunks)
        """
        # Get top matches from full manual
        full_chunks = self._top_matches(self.full_index, query_embedding, top_k)
        
        # Get version compatibility chunks
        version_chunks = self._top_matches(self.versions_index, query_embedding, VERSION_CHECK_TOP_K)
        
        return {
            "full": [self._chunk_to_dict(chunk) for chunk in full_chunks],
            "versions": [self._chunk_to_dict(chunk) for chunk in version_chunks]
        }
    
    def _chunk_to_dict(self, chunk: Chunk) -> Dict:
        """Convert chunk to dictionary format"""
        result = {
            "id": chunk.id,
            "content": chunk.content,
            "edition": chunk.edition,
            "metadata": chunk.metadata
        }
        return result

def create_embedding(text: str) -> List[float]:
    """Create embedding for text using OpenAI API"""
    if not OPENAI_API_KEY:
        # Fallback: create a simple hash-based embedding
        return _create_fallback_embedding(text)
    
    client = OpenAI(api_key=OPENAI_API_KEY)
    try:
        response = client.embeddings.create(
            model="text-embedding-3-large",
            input=text
        )
        return response.data[0].embedding
    except Exception as e:
        print(f"Error creating embedding: {e}")
        return _create_fallback_embedding(text)

def _create_fallback_embedding(text: str, dimension: int = 3072) -> List[float]:
    """Create a fallback embedding when API is not available"""
    words = text.lower().split()
    embedding = [0.0] * dimension
    
    for word in words:
        hash_val = abs(hash(word))
        dim = hash_val % dimension
        embedding[dim] += 1.0 / len(words) if words else 1.0
    
    # Normalize to unit length
    magnitude = math.sqrt(sum(x * x for x in embedding))
    if magnitude > 0:
        embedding = [x / magnitude for x in embedding]
    
    return embedding

# Global RAG store instance
rag_store = RAGStore()

