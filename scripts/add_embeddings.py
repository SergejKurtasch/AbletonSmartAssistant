#!/usr/bin/env python3
"""
Script to add embeddings to existing chunks.

Loads chunks from JSON file, creates embeddings using OpenAI API
(model text-embedding-3-large) and saves updated JSON with embeddings.

Usage:
    python scripts/add_embeddings.py \
        --input data/live12-manual-chunks.json \
        --output data/live12-manual-chunks-with-embeddings.json \
        --openai-api-key $OPENAI_API_KEY
"""

import argparse
import json
import os
import re
import time
from pathlib import Path
from typing import List, Dict, Optional


def estimate_tokens(text: str) -> int:
    """Estimate token count (approximately 1 token = 4 characters)."""
    return len(text) // 4


def get_max_tokens_for_model(model: str) -> int:
    """Returns maximum token count for the model."""
    # OpenAI embedding models usually support up to 8192 tokens
    # Leave ~500 tokens margin for safety
    return 7500


def get_embedding_dimension(model: str) -> int:
    """Returns embedding dimension for the model."""
    if "text-embedding-3-large" in model:
        return 3072
    elif "text-embedding-3-small" in model:
        return 1536
    elif "text-embedding-ada-002" in model:
        return 1536
    else:
        # Default for unknown models
        return 1536


def split_text_by_tokens(text: str, max_tokens: int) -> List[str]:
    """Splits text into parts that do not exceed max_tokens."""
    max_chars = max_tokens * 4  # Approximately: 1 token = 4 characters
    parts = []
    
    # First try to split by paragraphs
    paragraphs = text.split('\n\n')
    current_part = []
    current_size = 0
    
    for para in paragraphs:
        para_size = len(para)
        if current_size + para_size > max_chars and current_part:
            parts.append('\n\n'.join(current_part))
            current_part = [para]
            current_size = para_size
        else:
            current_part.append(para)
            current_size += para_size + 2  # +2 for '\n\n' separator
    
    if current_part:
        parts.append('\n\n'.join(current_part))
    
    # If parts are still too large, split by sentences
    final_parts = []
    for part in parts:
        if len(part) <= max_chars:
            final_parts.append(part)
        else:
            # Split by sentences
            sentences = re.split(r'([.!?]+\s+)', part)
            current_sent = []
            current_size = 0
            
            for i in range(0, len(sentences), 2):
                if i + 1 < len(sentences):
                    sentence = sentences[i] + sentences[i + 1]
                else:
                    sentence = sentences[i]
                
                sent_size = len(sentence)
                if current_size + sent_size > max_chars and current_sent:
                    final_parts.append(' '.join(current_sent))
                    current_sent = [sentence]
                    current_size = sent_size
                else:
                    current_sent.append(sentence)
                    current_size += sent_size + 1
            
            if current_sent:
                final_parts.append(' '.join(current_sent))
    
    return final_parts if final_parts else [text[:max_chars]]


def create_embeddings_openai(
    texts: List[str],
    api_key: str,
    model: str = "text-embedding-3-large",
    batch_size: int = 100
) -> List[List[float]]:
    """Creates embeddings via OpenAI API."""
    import openai
    
    client = openai.OpenAI(api_key=api_key)
    embeddings = []
    max_tokens = get_max_tokens_for_model(model)
    embedding_dim = get_embedding_dimension(model)
    
    print(f"Creating embeddings using model {model}...")
    print(f"Embedding dimension: {embedding_dim}")
    print(f"Maximum tokens per text: {max_tokens}")
    
    # Filter and split texts that are too large
    processed_texts = []
    text_indices = []  # Track original indices
    
    for idx, text in enumerate(texts):
        tokens = estimate_tokens(text)
        if tokens > max_tokens:
            print(f"Warning: Text {idx} is too large ({tokens} tokens), splitting...")
            # Split text into smaller parts
            parts = split_text_by_tokens(text, max_tokens)
            for part in parts:
                processed_texts.append(part)
                text_indices.append(idx)
        else:
            processed_texts.append(text)
            text_indices.append(idx)
    
    # Process texts in batches
    total_batches = (len(processed_texts) + batch_size - 1) // batch_size
    for i in range(0, len(processed_texts), batch_size):
        batch = processed_texts[i:i + batch_size]
        batch_num = i // batch_size + 1
        print(f"Processing batch {batch_num}/{total_batches} ({len(batch)} texts)...")
        
        # Check size of each text in batch
        valid_batch = []
        batch_indices = []
        for j, text in enumerate(batch):
            tokens = estimate_tokens(text)
            if tokens > max_tokens:
                print(f"Warning: Text in batch is still too large ({tokens} tokens), truncating...")
                # Truncate text to maximum size
                max_chars = max_tokens * 4
                text = text[:max_chars]
            valid_batch.append(text)
            batch_indices.append(i + j)
        
        try:
            response = client.embeddings.create(
                model=model,
                input=valid_batch
            )
            
            batch_embeddings = [item.embedding for item in response.data]
            embeddings.extend(batch_embeddings)
            
            # Rate limiting: small delay between batches
            if i + batch_size < len(processed_texts):
                time.sleep(0.1)
        
        except Exception as e:
            print(f"Error processing batch: {e}")
            # Fall back to processing one text at a time if batch fails
            print("Attempting to process texts one by one...")
            for text in valid_batch:
                try:
                    response = client.embeddings.create(
                        model=model,
                        input=[text]
                    )
                    embeddings.append(response.data[0].embedding)
                except Exception as e2:
                    print(f"Error processing individual text: {e2}")
                    # Return zero embedding if we can't recover
                    embeddings.append([0.0] * embedding_dim)
    
    # If texts were split earlier, average embeddings for each original text
    if len(processed_texts) > len(texts):
        # Group embeddings by original index
        final_embeddings = []
        current_idx = 0
        for orig_idx in range(len(texts)):
            # Collect all embeddings that belong to this text
            text_embeddings = []
            while current_idx < len(embeddings) and text_indices[current_idx] == orig_idx:
                text_embeddings.append(embeddings[current_idx])
                current_idx += 1
            
            if text_embeddings:
                # Average embeddings to get one vector
                avg_embedding = [sum(vals) / len(vals) for vals in zip(*text_embeddings)]
                final_embeddings.append(avg_embedding)
            else:
                # Default to zero vector if no data
                final_embeddings.append([0.0] * embedding_dim)
        
        return final_embeddings
    
    return embeddings


def load_env_file(env_path: Optional[Path] = None) -> None:
    """Loads environment variables from .env file if they are not set."""
    if env_path is None:
        # Search for .env file in current directory and parent directories
        current_dir = Path.cwd()
        for _ in range(10):  # Limit search depth
            candidate = current_dir / ".env"
            if candidate.exists():
                env_path = candidate
                break
            parent = current_dir.parent
            if parent == current_dir:
                break
            current_dir = parent
    
    if env_path and env_path.exists():
        try:
            with open(env_path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    # Skip comments and empty lines
                    if not line or line.startswith('#'):
                        continue
                    # Parse KEY=VALUE pairs
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip().strip('"').strip("'")
                        # Set variable only if it's not already defined
                        if key and value and key not in os.environ:
                            os.environ[key] = value
        except Exception as e:
            print(f"Warning: Failed to load .env file: {e}")


def main():
    """Main function."""
    # Load environment variables from .env file
    load_env_file()
    
    parser = argparse.ArgumentParser(
        description="Adds embeddings to existing chunks from JSON file"
    )
    parser.add_argument(
        "--input",
        type=Path,
        #default=Path("data/live12-manual-chunks.json"),
        default=Path("data/Ableton-versions-diff-chunks.json"),
        help="Path to input JSON file with chunks"
    )
    parser.add_argument(
        "--output",
        type=Path,
        #default=Path("data/live12-manual-chunks-with-embeddings.json"),
        default=Path("data/Ableton-versions-diff-chunks-with-embeddings.json"),
        help="Path to output JSON file with embeddings"
    )
    parser.add_argument(
        "--openai-api-key",
        type=str,
        default=None,
        help="OpenAI API key (or set OPENAI_API_KEY in env or .env file)"
    )
    parser.add_argument(
        "--embedding-model",
        type=str,
        default="text-embedding-3-large",
        choices=["text-embedding-3-large", "text-embedding-3-small", "text-embedding-ada-002"],
        help="OpenAI model for creating embeddings"
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=100,
        help="Batch size for processing (default 100)"
    )
    
    args = parser.parse_args()
    
    # Prefer explicit CLI key, otherwise use environment variable
    if not args.openai_api_key:
        args.openai_api_key = os.getenv("OPENAI_API_KEY")
    
    if not args.openai_api_key:
        raise ValueError(
            "OpenAI API key required. Set --openai-api-key, environment variable "
            "OPENAI_API_KEY or add OPENAI_API_KEY to .env file"
        )
    
    # Check if input file exists
    if not args.input.exists():
        raise FileNotFoundError(f"Input file not found: {args.input}")
    
    print("=" * 60)
    print("Adding embeddings to chunks")
    print("=" * 60)
    print(f"Input file: {args.input}")
    print(f"Output file: {args.output}")
    print(f"Model: {args.embedding_model}")
    print()
    
    # Load chunks
    print("Loading chunks...")
    with open(args.input, 'r', encoding='utf-8') as f:
        chunks = json.load(f)
    
    print(f"Loaded {len(chunks)} chunks")
    
    # Extract texts for creating embeddings
    texts = [chunk['content'] for chunk in chunks]
    
    # Create embeddings
    print("\nCreating embeddings...")
    embeddings = create_embeddings_openai(
        texts,
        args.openai_api_key,
        model=args.embedding_model,
        batch_size=args.batch_size
    )
    
    print(f"Created {len(embeddings)} embeddings")
    
    # Add embeddings to chunks
    print("\nAdding embeddings to chunks...")
    for idx, chunk in enumerate(chunks):
        chunk['embedding'] = embeddings[idx]
        # Update metadata with embedding size information
        if 'metadata' not in chunk:
            chunk['metadata'] = {}
        chunk['metadata']['embedding_model'] = args.embedding_model
        chunk['metadata']['embedding_dimension'] = get_embedding_dimension(args.embedding_model)
    
    # Save updated chunks
    print(f"\nSaving to {args.output}...")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    
    with open(args.output, 'w', encoding='utf-8') as f:
        json.dump(chunks, f, ensure_ascii=False, indent=2)
    
    print(f"✓ Successfully saved {len(chunks)} chunks with embeddings to {args.output}")
    
    # Statistics
    embedding_dim = get_embedding_dimension(args.embedding_model)
    total_vectors = len(embeddings)
    print(f"\nStatistics:")
    print(f"  - Number of chunks: {len(chunks)}")
    print(f"  - Embedding dimension: {embedding_dim}")
    print(f"  - Total vector size: {total_vectors * embedding_dim} numbers")
    print("=" * 60)


if __name__ == "__main__":
    main()

