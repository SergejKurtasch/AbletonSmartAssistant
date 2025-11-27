#!/usr/bin/env python3
"""
Simple script to process PDF manual into JSON for vector search.

Processes live12-manual-en.pdf:
- Skips first 21 pages
- Splits by second-level headings (e.g., 1.3, 1.4, 8.1, 8.2)
- Each second-level heading = separate chunk
- Large chapters are split into multiple parts
- Saves result to JSON

Usage:
    python scripts/process_manual.py
"""

import json
import re
from pathlib import Path
from typing import List, Dict, Optional
from pypdf import PdfReader


class Section:
    """Represents a section with a second-level heading."""
    def __init__(self, title: str, content: str, page: int):
        self.title = title
        self.content = content
        self.page = page
        self.section_id = self._extract_section_id(title)
    
    def _extract_section_id(self, title: str) -> Optional[str]:
        """Extracts section identifier (e.g., '1.3' from '1.3 Introduction')."""
        match = re.match(r'^(\d+\.\d+)', title.strip())
        return match.group(1) if match else None
    
    def to_dict(self) -> Dict:
        """Converts section to dictionary for JSON."""
        return {
            "section_id": self.section_id,
            "title": self.title,
            "content": self.content,
            "page": self.page,
            "char_count": len(self.content),
        }


def is_level2_heading(line: str) -> bool:
    """
    Determines if a line is a second-level heading.
    Second-level heading has format: X.Y Heading
    where X and Y are digits (e.g., 1.3, 8.1, 25.2)
    """
    line = line.strip()
    # Pattern: starts with digit, dot, digit, space, then text
    pattern = r'^\d+\.\d+\s+[A-Z]'
    return bool(re.match(pattern, line))


def estimate_tokens(text: str) -> int:
    """Estimate token count (approximately 1 token = 4 characters)."""
    return len(text) // 4


def split_large_content(content: str, max_tokens: int = 2000) -> List[str]:
    """
    Splits large content into parts if it exceeds max_tokens.
    Uses simple paragraph-based splitting algorithm.
    """
    estimated_tokens = estimate_tokens(content)
    if estimated_tokens <= max_tokens:
        return [content]
    
    # Split by double line breaks (paragraphs)
    paragraphs = content.split('\n\n')
    parts = []
    current_part = []
    current_tokens = 0
    
    for para in paragraphs:
        para_tokens = estimate_tokens(para)
        
        # If one paragraph is already larger than limit, split it by sentences
        if para_tokens > max_tokens:
            # Save current part if it's not empty
            if current_part:
                parts.append('\n\n'.join(current_part))
                current_part = []
                current_tokens = 0
            
            # Split large paragraph by sentences
            sentences = re.split(r'([.!?]+\s+)', para)
            current_sent = []
            sent_tokens = 0
            
            for i in range(0, len(sentences), 2):
                if i + 1 < len(sentences):
                    sentence = sentences[i] + sentences[i + 1]
                else:
                    sentence = sentences[i]
                
                sent_tokens = estimate_tokens(sentence)
                
                if current_tokens + sent_tokens > max_tokens and current_sent:
                    parts.append(' '.join(current_sent))
                    current_sent = [sentence]
                    current_tokens = sent_tokens
                else:
                    current_sent.append(sentence)
                    current_tokens += sent_tokens
            
            if current_sent:
                parts.append(' '.join(current_sent))
                current_tokens = 0
        else:
            # Regular paragraph
            if current_tokens + para_tokens > max_tokens and current_part:
                parts.append('\n\n'.join(current_part))
                current_part = [para]
                current_tokens = para_tokens
            else:
                current_part.append(para)
                current_tokens += para_tokens + 2  # +2 for '\n\n'
    
    # Add last part
    if current_part:
        parts.append('\n\n'.join(current_part))
    
    return parts if parts else [content]


def extract_sections_from_pdf(pdf_path: Path, skip_pages: int = 21) -> List[Section]:
    """
    Extracts sections from PDF, grouping by second-level headings.
    """
    reader = PdfReader(str(pdf_path))
    sections = []
    current_section: Optional[Section] = None
    current_content = []
    current_page = skip_pages
    
    print(f"Processing PDF: {pdf_path.name}")
    print(f"Skipping first {skip_pages} pages...")
    print(f"Total pages in PDF: {len(reader.pages)}")
    
    for page_num in range(skip_pages, len(reader.pages)):
        try:
            text = reader.pages[page_num].extract_text()
            if not text.strip():
                continue
            
            lines = text.split('\n')
            
            for line in lines:
                line = line.strip()
                
                # Skip empty lines, but preserve them for formatting
                if not line:
                    if current_content:
                        current_content.append('')
                    continue
                
                # Check if line is a second-level heading
                if is_level2_heading(line):
                    # Save previous section
                    if current_section is not None:
                        current_section.content = '\n'.join(current_content).strip()
                        if current_section.content:
                            sections.append(current_section)
                    
                    # Start new section
                    current_section = Section(
                        title=line,
                        content='',
                        page=page_num + 1
                    )
                    current_content = []
                else:
                    # Add line to current section
                    if current_section is None:
                        # If no section yet, create a temporary one
                        # (in case document doesn't start with second-level heading)
                        current_section = Section(
                            title="Introduction",
                            content='',
                            page=page_num + 1
                        )
                    current_content.append(line)
        
        except Exception as e:
            print(f"Error processing page {page_num + 1}: {e}")
            continue
    
    # Save last section
    if current_section is not None:
        current_section.content = '\n'.join(current_content).strip()
        if current_section.content:
            sections.append(current_section)
    
    print(f"Extracted {len(sections)} sections with second-level headings")
    return sections


def create_chunks_from_sections(sections: List[Section], max_tokens: int = 2000) -> List[Dict]:
    """
    Creates chunks from sections. Each second-level section = separate chunk.
    Large sections are split into multiple parts.
    """
    chunks = []
    
    for section in sections:
        # Check section size
        content_parts = split_large_content(section.content, max_tokens)
        
        if len(content_parts) == 1:
            # Section fits in one chunk
            chunk = {
                "id": f"{section.section_id or 'unknown'}-1",
                "section_id": section.section_id,
                "title": section.title,
                "content": f"{section.title}\n\n{section.content}",
                "page": section.page,
                "metadata": {
                    "section_id": section.section_id,
                    "title": section.title,
                    "page": section.page,
                    "char_count": len(section.content),
                    "token_estimate": estimate_tokens(section.content),
                }
            }
            chunks.append(chunk)
        else:
            # Section is split into multiple parts
            for idx, part in enumerate(content_parts, start=1):
                chunk = {
                    "id": f"{section.section_id or 'unknown'}-{idx}",
                    "section_id": section.section_id,
                    "title": f"{section.title} (Part {idx})",
                    "content": f"{section.title} (Part {idx})\n\n{part}",
                    "page": section.page,
                    "metadata": {
                        "section_id": section.section_id,
                        "title": section.title,
                        "part": idx,
                        "total_parts": len(content_parts),
                        "page": section.page,
                        "char_count": len(part),
                        "token_estimate": estimate_tokens(part),
                    }
                }
                chunks.append(chunk)
    
    return chunks


def main():
    """Main processing function."""
    # File paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    # pdf_path = project_root / "data" / "live12-manual-en.pdf"
    # output_path = project_root / "data" / "live12-manual-chunks.json"
    pdf_path = project_root / "data" / "Ableton-versions-diff.pdf"
    output_path = project_root / "data" / "Ableton-versions-diff-chunks.json"
    


    # Check if PDF exists
    if not pdf_path.exists():
        print(f"Error: file not found: {pdf_path}")
        return
    
    print("=" * 60)
    print("Processing PDF manual")
    print("=" * 60)
    
    # Extract sections
    # sections = extract_sections_from_pdf(pdf_path, skip_pages=21)
    sections = extract_sections_from_pdf(pdf_path, skip_pages=0)
    
    if not sections:
        print("Error: failed to extract sections from PDF")
        return
    
    # Create chunks
    print("\nCreating chunks...")
    chunks = create_chunks_from_sections(sections, max_tokens=2000)
    
    print(f"Created {len(chunks)} chunks from {len(sections)} sections")
    
    # Statistics
    total_chars = sum(len(chunk["content"]) for chunk in chunks)
    avg_chars = total_chars // len(chunks) if chunks else 0
    print(f"Total text volume: {total_chars:,} characters")
    print(f"Average chunk size: {avg_chars:,} characters")
    
    # Save to JSON
    print(f"\nSaving to {output_path}...")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(chunks, f, ensure_ascii=False, indent=2)
    
    print(f"✓ Successfully saved {len(chunks)} chunks to {output_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()


