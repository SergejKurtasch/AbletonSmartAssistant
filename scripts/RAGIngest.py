#!/usr/bin/env python3
"""
Preprocess Ableton PDFs into two vector indices (Full + Lite diff).
Uses structure-aware chunking (by sections) and OpenAI embeddings.

Usage:
    python scripts/RAGIngest.py \
        --full-pdf data/live12-manual-en.pdf \
        --lite-pdf data/Ableton-versions.pdf \
        --out-dir data \
        --openai-api-key $OPENAI_API_KEY \
        --toc-pages 21
"""
from __future__ import annotations

import argparse
import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

import openai
from pypdf import PdfReader


@dataclass
class Section:
    """Structured section extracted from the PDF."""
    title: str
    content: str
    page: int
    level: int  # Nesting level (1 = chapter, 2 = subsection, etc.)
    chapter: Optional[str] = None  # Chapter identifier pulled from the table of contents


@dataclass
class TOCEntry:
    """Entry from the table of contents."""
    title: str
    page: int
    level: int
    chapter: Optional[str] = None


@dataclass
class Chunk:
    id: str
    content: str
    edition: str | None
    embedding: List[float]
    metadata: dict  # Title, page, chapter metadata

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "content": self.content,
            "edition": self.edition,
            "embedding": self.embedding,
            "metadata": self.metadata,
        }


def estimate_tokens(text: str) -> int:
    """Estimate token count (1 token ≈ 4 characters)."""
    return len(text) // 4


def get_max_tokens_for_model(model: str) -> int:
    """Return the maximum token budget for the model."""
    # OpenAI embedding models typically allow up to 8192 tokens
    # Keep roughly 500 tokens in reserve for safety
    return 7500


def get_embedding_dimension(model: str) -> int:
    """Return embedding dimensionality for the model."""
    if "text-embedding-3-large" in model:
        return 3072
    elif "text-embedding-3-small" in model:
        return 1536
    elif "text-embedding-ada-002" in model:
        return 1536
    else:
        # Default to ada-style dimensions for unknown models
        return 1536


def split_text_by_tokens(text: str, max_tokens: int) -> List[str]:
    """Split text into chunks that do not exceed max_tokens."""
    max_chars = max_tokens * 4  # Rough conversion: 1 token ≈ 4 characters
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
            current_size += para_size + 2  # +2 accounts for the separating '\n\n'
    
    if current_part:
        parts.append('\n\n'.join(current_part))
    
    # If chunks are still too large, split by sentences
    final_parts = []
    for part in parts:
        if len(part) <= max_chars:
            final_parts.append(part)
        else:
            # Break the content into sentences
            sentences = re.split(r'[.!?]+\s+', part)
            current_sent = []
            current_size = 0
            
            for sent in sentences:
                sent_size = len(sent)
                if current_size + sent_size > max_chars and current_sent:
                    final_parts.append('. '.join(current_sent) + '.')
                    current_sent = [sent]
                    current_size = sent_size
                else:
                    current_sent.append(sent)
                    current_size += sent_size + 2
            
            if current_sent:
                final_parts.append('. '.join(current_sent))
    
    return final_parts if final_parts else [text[:max_chars]]


def extract_toc(pdf_path: Path, max_toc_pages: int = 21) -> List[TOCEntry]:
    """Extract the table of contents from the first pages of the PDF."""
    reader = PdfReader(str(pdf_path))
    toc_entries = []
    
    print(f"Extracting table of contents from first {max_toc_pages} pages...")
    
    for page_num in range(min(max_toc_pages, len(reader.pages))):
        text = reader.pages[page_num].extract_text()
        lines = text.split('\n')
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            
            # Look for typical TOC lines such as:
            # "1. Introduction ................ 15"
            # "Chapter 2: MIDI Effects .......... 45"
            # "1.1. Subtopic ................... 67"
            
            # Find lines that end with a page number
            page_match = re.search(r'(\d+)\s*$', line)
            if page_match:
                page_num_ref = int(page_match.group(1))
                title = line[:page_match.start()].strip()
                
                # Remove dot leaders
                title = re.sub(r'\.+\s*$', '', title).strip()
                
                if title and len(title) > 3:  # Require a minimal title length
                    # Determine heading level by prefix or indentation cues
                    level = 1
                    if re.match(r'^\d+\.\d+', title):
                        level = 2
                    elif re.match(r'^\d+\.\d+\.\d+', title):
                        level = 3
                    
                    # Capture an explicit chapter identifier if present
                    chapter_match = re.match(r'^(\d+|[A-Z][a-z]+)', title)
                    chapter = chapter_match.group(1) if chapter_match else None
                    
                    toc_entries.append(TOCEntry(
                        title=title,
                        page=page_num_ref,
                        level=level,
                        chapter=chapter
                    ))
    
    print(f"Extracted {len(toc_entries)} TOC entries")
    return toc_entries


def extract_pdf_structure(path: Path, skip_toc_pages: int = 21) -> List[Section]:
    """Extract PDF text while preserving headings and section boundaries."""
    reader = PdfReader(str(path))
    sections = []
    current_section = None
    current_content = []
    current_page = skip_toc_pages
    
    print(f"Extracting content from page {skip_toc_pages + 1} onwards...")
    
    for page_num in range(skip_toc_pages, len(reader.pages)):
        text = reader.pages[page_num].extract_text()
        if not text.strip():
            continue
        
        lines = text.split('\n')
        
        for line in lines:
            line = line.strip()
            if not line:
                if current_content:
                    current_content.append('')
                continue
            
            # Detect headings using a few heuristics:
            # - Short lines (typically < 100 characters)
            # - All caps or otherwise emphasized text
            # - Explicit numbering such as 1.1, 2.3, etc.
            # - Standalone lines without trailing punctuation
            
            is_heading = False
            level = 1
            
            # Heading patterns
            if re.match(r'^\d+\.\d+\.?\s+[A-Z]', line):  # "1.1 Introduction"
                is_heading = True
                level = 2
            elif re.match(r'^\d+\.\s+[A-Z]', line):  # "1. Introduction"
                is_heading = True
                level = 1
            elif (len(line) < 100 and 
                  line.isupper() and 
                  len(line.split()) < 10):  # ALL CAPS and concise
                is_heading = True
                level = 1
            elif (len(line) < 80 and 
                  not line.endswith('.') and 
                  not line.endswith(',') and
                  len(line.split()) < 8 and
                  line[0].isupper()):  # Short line that starts with uppercase
                is_heading = True
                level = 2
            
            if is_heading:
                # Persist the previous section before starting the new one
                if current_section and current_content:
                    current_section.content = '\n'.join(current_content).strip()
                    if current_section.content:
                        sections.append(current_section)
                
                # Start a new section
                current_section = Section(
                    title=line,
                    content='',
                    page=page_num + 1,
                    level=level
                )
                current_content = []
            else:
                # Append the line to the current section content
                if current_section is None:
                    # Seed the first section with a default heading if needed
                    current_section = Section(
                        title="Introduction",
                        content='',
                        page=page_num + 1,
                        level=1
                    )
                current_content.append(line)
        
        # Insert a page break marker
        if current_content:
            current_content.append(f'\n[Page {page_num + 1}]')
    
    # Persist the trailing section after the loop
    if current_section and current_content:
        current_section.content = '\n'.join(current_content).strip()
        if current_section.content:
            sections.append(current_section)
    
    print(f"Extracted {len(sections)} sections")
    return sections


def match_sections_with_toc(sections: List[Section], toc: List[TOCEntry]) -> None:
    """Align sections with TOC entries to enrich metadata."""
    toc_by_page = {entry.page: entry for entry in toc}
    
    for section in sections:
        # Find the closest TOC entry by page
        closest_toc = None
        min_diff = float('inf')
        
        for toc_entry in toc:
            diff = abs(toc_entry.page - section.page)
            if diff < min_diff and diff < 10:  # Only match if within 10 pages
                min_diff = diff
                closest_toc = toc_entry
        
        if closest_toc:
            section.chapter = closest_toc.chapter


def chunk_by_sections(
    sections: List[Section], 
    max_tokens: int = 1000,
    overlap_tokens: int = 100
) -> Iterable[dict]:
    """Chunk sections while preserving topical continuity."""
    current_chunk_sections = []
    current_tokens = 0
    
    for section in sections:
        section_text = f"{section.title}\n{section.content}"
        section_tokens = estimate_tokens(section_text)
        
        # Split oversized sections into smaller pieces
        if section_tokens > max_tokens:
            # Emit the chunk collected so far
            if current_chunk_sections:
                yield {
                    'content': '\n\n'.join([f"{s.title}\n{s.content}" for s in current_chunk_sections]),
                    'metadata': {
                        'title': current_chunk_sections[0].title,
                        'page': current_chunk_sections[0].page,
                        'chapter': current_chunk_sections[0].chapter,
                        'sections': len(current_chunk_sections)
                    }
                }
                current_chunk_sections = []
                current_tokens = 0
            
            # Break the large section into sub-chunks
            paragraphs = section.content.split('\n\n')
            sub_chunk = [section.title]
            sub_tokens = estimate_tokens(section.title)
            
            for para in paragraphs:
                para_tokens = estimate_tokens(para)
                if sub_tokens + para_tokens > max_tokens and sub_chunk:
                    yield {
                        'content': '\n\n'.join(sub_chunk),
                        'metadata': {
                            'title': section.title,
                            'page': section.page,
                            'chapter': section.chapter,
                            'sections': 1
                        }
                    }
                    sub_chunk = [section.title]
                    sub_tokens = estimate_tokens(section.title)
                
                sub_chunk.append(para)
                sub_tokens += para_tokens
            
            if sub_chunk:
                yield {
                    'content': '\n\n'.join(sub_chunk),
                    'metadata': {
                        'title': section.title,
                        'page': section.page,
                        'chapter': section.chapter,
                        'sections': 1
                    }
                }
        
        # Flush the chunk if adding this section would exceed the limit
        elif current_tokens + section_tokens > max_tokens and current_chunk_sections:
            yield {
                'content': '\n\n'.join([f"{s.title}\n{s.content}" for s in current_chunk_sections]),
                'metadata': {
                    'title': current_chunk_sections[0].title,
                    'page': current_chunk_sections[0].page,
                    'chapter': current_chunk_sections[0].chapter,
                    'sections': len(current_chunk_sections)
                }
            }
            
            # Start a new chunk that overlaps with the last section
            if overlap_tokens > 0 and current_chunk_sections:
                last_section = current_chunk_sections[-1]
                overlap_text = last_section.content[-overlap_tokens*4:]  # Approximate overlap_tokens characters
                current_chunk_sections = [Section(
                    title=last_section.title,
                    content=overlap_text,
                    page=last_section.page,
                    level=last_section.level,
                    chapter=last_section.chapter
                )]
                current_tokens = estimate_tokens(overlap_text)
            else:
                current_chunk_sections = []
                current_tokens = 0
        
        # Append the section to the active chunk
        current_chunk_sections.append(section)
        current_tokens += section_tokens
    
    # Flush the final chunk
    if current_chunk_sections:
        yield {
            'content': '\n\n'.join([f"{s.title}\n{s.content}" for s in current_chunk_sections]),
            'metadata': {
                'title': current_chunk_sections[0].title,
                'page': current_chunk_sections[0].page,
                'chapter': current_chunk_sections[0].chapter,
                'sections': len(current_chunk_sections)
            }
        }


def create_embeddings_openai(
    texts: List[str],
    api_key: str,
    model: str = "text-embedding-3-large",
    batch_size: int = 100
) -> List[List[float]]:
    """Create embeddings via the OpenAI API."""
    client = openai.OpenAI(api_key=api_key)
    embeddings = []
    max_tokens = get_max_tokens_for_model(model)
    embedding_dim = get_embedding_dimension(model)
    
    print(f"Creating embeddings using {model}...")
    
    # Filter and split texts that are still too large
    processed_texts = []
    text_indices = []  # Track original indices
    
    for idx, text in enumerate(texts):
        tokens = estimate_tokens(text)
        if tokens > max_tokens:
            print(f"Warning: Text {idx} is too large ({tokens} tokens), splitting...")
            # Break the text into smaller pieces
            parts = split_text_by_tokens(text, max_tokens)
            for part in parts:
                processed_texts.append(part)
                text_indices.append(idx)
        else:
            processed_texts.append(text)
            text_indices.append(idx)
    
    # Process texts in batches
    for i in range(0, len(processed_texts), batch_size):
        batch = processed_texts[i:i + batch_size]
        print(f"Processing batch {i // batch_size + 1}/{(len(processed_texts) + batch_size - 1) // batch_size}...")
        
        # Verify the size of every text inside the batch
        valid_batch = []
        batch_indices = []
        for j, text in enumerate(batch):
            tokens = estimate_tokens(text)
            if tokens > max_tokens:
                print(f"Warning: Text in batch is still too large ({tokens} tokens), truncating...")
                # Trim the text down to the maximum size
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
            
            # Rate limiting: keep a short delay between batches
            if i + batch_size < len(processed_texts):
                time.sleep(0.1)
        
        except Exception as e:
            print(f"Error processing batch: {e}")
            # Fall back to per-text processing if the batch fails
            print("Attempting to process texts individually...")
            for text in valid_batch:
                try:
                    response = client.embeddings.create(
                        model=model,
                        input=[text]
                    )
                    embeddings.append(response.data[0].embedding)
                except Exception as e2:
                    print(f"Error processing individual text: {e2}")
                    # Emit a zero embedding when we cannot recover
                    embeddings.append([0.0] * embedding_dim)
    
    # If texts were split earlier, average the embeddings per original text
    if len(processed_texts) > len(texts):
        # Group embeddings by the original index
        final_embeddings = []
        current_idx = 0
        for orig_idx in range(len(texts)):
            # Collect all embeddings that belong to this text
            text_embeddings = []
            while current_idx < len(embeddings) and text_indices[current_idx] == orig_idx:
                text_embeddings.append(embeddings[current_idx])
                current_idx += 1
            
            if text_embeddings:
                # Average embeddings to get a single vector
                avg_embedding = [sum(vals) / len(vals) for vals in zip(*text_embeddings)]
                final_embeddings.append(avg_embedding)
            else:
                # Default to a zero vector if we somehow have no data
                final_embeddings.append([0.0] * embedding_dim)
        
        return final_embeddings
    
    return embeddings


def embed_chunks(
    chunk_data: List[dict],
    api_key: str,
    edition: str | None,
    model: str = "text-embedding-3-large"
) -> List[Chunk]:
    """Create chunk records that include embeddings."""
    texts = [chunk['content'] for chunk in chunk_data]
    embeddings = create_embeddings_openai(texts, api_key, model)
    
    return [
        Chunk(
            id=f"{edition or 'full'}-{idx}",
            content=chunk['content'],
            edition=edition,
            embedding=embeddings[idx],
            metadata=chunk['metadata']
        )
        for idx, chunk in enumerate(chunk_data)
    ]


def write_index(chunks: List[Chunk], destination: Path) -> None:
    """Write the index to disk as JSON."""
    destination.write_text(
        json.dumps([chunk.to_dict() for chunk in chunks], ensure_ascii=False, indent=2)
    )
    print(f"Wrote {len(chunks)} chunks → {destination}")


def load_env_file(env_path: Optional[Path] = None) -> None:
    """Load environment variables from a .env file if they are unset."""
    if env_path is None:
        # Search for a .env file in the current directory and parents
        current_dir = Path.cwd()
        for _ in range(10):  # Limit how far up we traverse
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
                        # Only set the variable if it is not defined yet
                        if key and value and key not in os.environ:
                            os.environ[key] = value
        except Exception as e:
            print(f"Warning: Could not load .env file: {e}")


def main() -> None:
    # Load .env variables if needed so argparse defaults can pick them up
    load_env_file()
    
    parser = argparse.ArgumentParser(
        description="Create vector indices from Ableton PDF documentation"
    )
    parser.add_argument("--full-pdf", required=True, type=Path, help="Path to full manual PDF")
    parser.add_argument("--lite-pdf", required=True, type=Path, help="Path to Lite differences PDF")
    parser.add_argument("--out-dir", default=Path("data"), type=Path, help="Output directory")
    parser.add_argument("--chunk-tokens", type=int, default=1000, help="Max tokens per chunk")
    parser.add_argument("--overlap-tokens", type=int, default=100, help="Overlap between chunks")
    parser.add_argument("--toc-pages", type=int, default=21, help="Number of TOC pages to skip")
    parser.add_argument(
        "--openai-api-key",
        type=str,
        default=None,
        help="OpenAI API key (or set OPENAI_API_KEY env var or .env file)"
    )
    parser.add_argument(
        "--embedding-model",
        type=str,
        default="text-embedding-3-large",
        choices=["text-embedding-3-large", "text-embedding-3-small", "text-embedding-ada-002"],
        help="OpenAI embedding model to use"
    )
    
    args = parser.parse_args()
    
    # Prefer the explicit CLI key, otherwise fall back to the env variable
    if not args.openai_api_key:
        args.openai_api_key = os.getenv("OPENAI_API_KEY")
    
    if not args.openai_api_key:
        raise ValueError(
            "OpenAI API key required. Set --openai-api-key, OPENAI_API_KEY env var, "
            "or add OPENAI_API_KEY to .env file"
        )
    
    args.out_dir.mkdir(parents=True, exist_ok=True)
    
    # Process the full Ableton manual
    print("\n" + "="*60)
    print("Processing Full manual...")
    print("="*60)
    
    full_toc = extract_toc(args.full_pdf, args.toc_pages)
    full_sections = extract_pdf_structure(args.full_pdf, skip_toc_pages=args.toc_pages)
    match_sections_with_toc(full_sections, full_toc)
    
    full_chunk_data = list(chunk_by_sections(
        full_sections,
        max_tokens=args.chunk_tokens,
        overlap_tokens=args.overlap_tokens
    ))
    
    print(f"Created {len(full_chunk_data)} chunks from {len(full_sections)} sections")
    
    full_chunks = embed_chunks(
        full_chunk_data,
        args.openai_api_key,
        edition=None,
        model=args.embedding_model
    )
    write_index(full_chunks, args.out_dir / "AbletonFullIndex.json")
    
    # Process the Lite-specific differences
    print("\n" + "="*60)
    print("Processing Lite diff...")
    print("="*60)
    
    lite_toc = extract_toc(args.lite_pdf, max_toc_pages=min(10, args.toc_pages))
    lite_sections = extract_pdf_structure(args.lite_pdf, skip_toc_pages=min(10, args.toc_pages))
    match_sections_with_toc(lite_sections, lite_toc)
    
    lite_chunk_data = list(chunk_by_sections(
        lite_sections,
        max_tokens=int(args.chunk_tokens * 0.6),
        overlap_tokens=int(args.overlap_tokens * 0.6)
    ))
    
    print(f"Created {len(lite_chunk_data)} chunks from {len(lite_sections)} sections")
    
    lite_chunks = embed_chunks(
        lite_chunk_data,
        args.openai_api_key,
        edition="lite",
        model=args.embedding_model
    )
    write_index(lite_chunks, args.out_dir / "AbletonLiteDiffIndex.json")
    
    print("\n" + "="*60)
    print("Done! Indices created successfully.")
    print("="*60)


if __name__ == "__main__":
    main()
