"""All nodes for LangGraph workflow"""
import json
import re
import base64
from typing import Dict, Literal
from openai import OpenAI
# Support both relative imports (for LangGraph Studio) and absolute imports (for direct run)
try:
    from .state import AgentState
    from .rag import rag_store, create_embedding
    from .config import OPENAI_API_KEY, OPENAI_MODEL, VISION_MODEL
except ImportError:
    from state import AgentState
    from rag import rag_store, create_embedding
    from config import OPENAI_API_KEY, OPENAI_MODEL, VISION_MODEL

client = OpenAI(api_key=OPENAI_API_KEY) if OPENAI_API_KEY else None

def detect_language(text: str) -> str:
    """Detect language from text. Returns 'ru' for Russian, 'en' for English, etc."""
    if not text:
        return "en"
    
    # Simple heuristic: check for Cyrillic characters
    cyrillic_count = sum(1 for char in text if '\u0400' <= char <= '\u04FF')
    total_letters = sum(1 for char in text if char.isalpha())
    
    if total_letters > 0 and cyrillic_count / total_letters > 0.1:
        return "ru"
    return "en"

def detect_user_intent(state: AgentState) -> AgentState:
    """Detect if user query is about Ableton or something else"""
    query = state.get("user_query", "")
    
    if not client:
        # Fallback: assume it's an Ableton question
        state["intent"] = "ableton_question"
        return state
    
    try:
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": "You are a classifier. Determine if the user's question is about Ableton Live software or something else. Respond with only 'ableton_question' or 'other'."
                },
                {
                    "role": "user",
                    "content": f"Question: {query}"
                }
            ],
            temperature=0.1,
            max_tokens=10
        )
        
        content = response.choices[0].message.content
        if content:
            intent = content.strip().lower()
            if "ableton" in intent:
                state["intent"] = "ableton_question"
            else:
                state["intent"] = "other"
        else:
            state["intent"] = "ableton_question"  # Default
    except Exception as e:
        print(f"Error detecting intent: {e}")
        state["intent"] = "ableton_question"  # Default to Ableton question
    
    return state

def check_ableton_version(state: AgentState) -> AgentState:
    """Check version compatibility for the user's query"""
    query = state.get("user_query", "")
    edition = state.get("ableton_edition", "Ableton Live Suite")
    
    # Skip version check if already done and user chose to proceed anyway
    # Check if user_choice indicates they want to proceed despite version issues
    user_choice = (state.get("user_choice") or "").lower()
    if "try anyway" in user_choice or "all the same" in user_choice or "proceed anyway" in user_choice:
        print(f"DEBUG: User chose to proceed anyway, setting allowed=True")
        state["allowed"] = True
        return state
    
    # If version check was already done, don't repeat it
    if "allowed" in state and state["allowed"] is not None:
        print(f"DEBUG: Version check already done, allowed={state['allowed']}, skipping")
        return state
    
    # Create embedding for query
    query_embedding = create_embedding(query)
    
    # Retrieve version compatibility chunks
    results = rag_store.retrieve(query_embedding, edition, top_k=2)
    version_chunks = results["versions"]
    
    if not version_chunks:
        # No version info found, assume allowed
        state["allowed"] = True
        return state
    
    # Check if any chunk indicates incompatibility
    version_text = "\n\n".join([chunk["content"] for chunk in version_chunks])
    
    if not client:
        # Fallback: assume allowed
        state["allowed"] = True
        return state
    
    try:
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": f"You are analyzing version compatibility for Ableton Live {edition}. Based on the version information provided, determine if the user's request is compatible with their edition. Respond with JSON: {{\"allowed\": true/false, \"explanation\": \"brief explanation\"}}"
                },
                {
                    "role": "user",
                    "content": f"User query: {query}\n\nVersion information:\n{version_text}"
                }
            ],
            temperature=0.3,
            response_format={"type": "json_object"}
        )
        
        result = json.loads(response.choices[0].message.content)
        state["allowed"] = result.get("allowed", True)
        state["version_explanation"] = result.get("explanation")
        print(f"DEBUG: Version check result: allowed={state['allowed']}, explanation={state.get('version_explanation')}")
    except Exception as e:
        print(f"Error checking version: {e}")
        state["allowed"] = True  # Default to allowed
    
    return state

def wait_for_version_choice(state: AgentState) -> AgentState:
    """Wait for user's choice when version is not compatible"""
    explanation = state.get("version_explanation", "This feature may not be available in your edition.")
    user_choice = state.get("user_choice", "")
    
    # If user already made a choice, don't wait again
    if user_choice:
        print(f"DEBUG: wait_for_version_choice: user_choice already set to '{user_choice}', skipping wait")
        # User choice will be processed by workflow routing
        # Clear action_required so workflow continues
        state["action_required"] = None
        return state
    
    state["action_required"] = "wait_version_choice"
    state["response_text"] = (
        f"⚠️ In the current version ({state['ableton_edition']}) this will likely not work "
        f"due to limitations: {explanation}\n\n"
        "Choose an action:\n"
        "1. Try anyway\n"
        "2. Formulate a new task"
    )
    
    return state

def retrieve_from_vectorstore(state: AgentState) -> AgentState:
    """Retrieve relevant documentation chunks"""
    query = state.get("user_query", "")
    edition = state.get("ableton_edition", "Ableton Live Suite")
    
    # Create embedding for query
    query_embedding = create_embedding(query)
    
    # Retrieve chunks
    results = rag_store.retrieve(query_embedding, edition, top_k=5)
    
    state["selected_chunks"] = results["full"]
    
    return state

def generate_full_answer(state: AgentState) -> AgentState:
    """Generate full answer with step-by-step instructions"""
    query = state.get("user_query", "")
    edition = state.get("ableton_edition", "Ableton Live Suite")
    chunks = state.get("selected_chunks") or []
    allowed = state.get("allowed", True)
    version_explanation = state.get("version_explanation")
    
    # Check if we already have a full_answer from RAGStore
    existing_answer = state.get("full_answer")
    
    if existing_answer and not chunks:
        # We have an answer from RAGStore, just need to break it into steps
        print(f"DEBUG: Using existing RAG answer, breaking into steps")
        print(f"DEBUG: existing_answer length={len(existing_answer)}")
        print(f"DEBUG: existing_answer preview (first 500 chars): {existing_answer[:500]}")
        print(f"DEBUG: chunks is empty: {len(chunks) == 0}")
        
        if not client:
            state["steps"] = []
            return state
        
        # Detect language from query and answer
        query_lang = detect_language(query)
        answer_lang = detect_language(existing_answer)
        # Use answer language as primary, fallback to query language
        detected_lang = answer_lang if answer_lang else query_lang
        print(f"DEBUG: Language detection - query_lang={query_lang}, answer_lang={answer_lang}, using={detected_lang}")
        print(f"DEBUG: Original answer length={len(existing_answer)}, first 200 chars: {existing_answer[:200]}")
        print(f"DEBUG: Original answer last 200 chars: {existing_answer[-200:]}")
        
        # Language-specific instructions
        lang_instructions = {
            "ru": "IMPORTANT: Extract steps EXACTLY from the original answer. Use THE EXACT SAME wording as in the original answer. Don't create new steps, don't rewrite text. Keep the same language (Russian).",
            "en": "IMPORTANT: Extract steps EXACTLY from the original answer. Use THE EXACT SAME wording as in the original answer. Don't create new steps, don't rewrite text. Keep the same language (English)."
        }
        lang_instruction = lang_instructions.get(detected_lang, lang_instructions["en"])
        
        # Language-specific keywords for click detection
        click_keywords = {
            "ru": ["click", "press", "select", "choose", "open"],
            "en": ["click", "press", "select", "choose", "open"]
        }
        click_words = click_keywords.get(detected_lang, click_keywords["en"])
        click_words_str = ", ".join(click_words)
        
        try:
            system_prompt = f"""You are Ableton Smart Assistant. Break down the provided answer into actionable steps.
User's edition: {edition}

Analyze the answer and extract step-by-step instructions. For each step, determine if it requires clicking a button or UI element in Ableton Live.
Words like {click_words_str} indicate requires_click=True.

{lang_instruction}"""
            
            user_prompt = f"""User question: {query}

Answer to break into steps:
{existing_answer}

Please extract step-by-step instructions from this answer in JSON format:
{{
  "explanation": "Brief summary (can reuse parts of the answer)",
  "steps": [
    {{
      "text": "Step description (EXACT text from the answer, word-for-word if possible)",
      "requires_click": true/false
    }}
  ]
}}

CRITICAL REQUIREMENTS:
- Extract steps in the EXACT order they appear in the answer
- Use the EXACT wording from the original answer - do NOT rewrite or rephrase
- Keep the SAME language as the original answer ({detected_lang})
- Do NOT create new steps - only extract what's already in the answer
- Do NOT change the number of steps - extract exactly what's there
- If a step mentions clicking, pressing, selecting buttons or UI elements, set requires_click=true
- Preserve the original formatting and style"""
            
            response = client.chat.completions.create(
                model=OPENAI_MODEL,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                temperature=0.1,  # Lower temperature for more precise extraction
                response_format={"type": "json_object"}
            )
            
            result = json.loads(response.choices[0].message.content)
            
            # Keep the original answer
            state["full_answer"] = existing_answer
            
            # Parse steps
            steps = result.get("steps", [])
            # Ensure all steps have required fields
            for step in steps:
                if "requires_click" not in step:
                    # Heuristic: check if step mentions click/press/select
                    step_text = step.get("text", "").lower()
                    step["requires_click"] = any(word in step_text for word in ["click", "press", "select", "choose", "open"])
                if "button_coords" not in step:
                    step["button_coords"] = None
            
            state["steps"] = steps
            print(f"DEBUG: Extracted {len(steps)} steps from RAG answer (language: {detected_lang})")
            if steps:
                print(f"DEBUG: First step: {steps[0].get('text', '')[:100]}...")
                print(f"DEBUG: Last step: {steps[-1].get('text', '')[:100]}...")
                # Verify language consistency
                first_step_lang = detect_language(steps[0].get('text', ''))
                if first_step_lang != detected_lang:
                    print(f"WARNING: Language mismatch! Expected {detected_lang}, got {first_step_lang} in first step")
                
                # Verify that steps match original answer structure
                # Check if step texts appear in original answer
                for i, step in enumerate(steps):
                    step_text = step.get('text', '')
                    # Check if step text (or significant part) appears in original answer
                    if step_text and len(step_text) > 20:
                        # Check first 50 chars of step
                        step_preview = step_text[:50].lower()
                        if step_preview not in existing_answer.lower():
                            print(f"WARNING: Step {i+1} text doesn't appear in original answer!")
                            print(f"  Step preview: {step_preview}")
                            print(f"  Checking if similar text exists...")
                print(f"DEBUG: Original answer preserved: {state.get('full_answer') == existing_answer}")
            
        except Exception as e:
            print(f"Error breaking answer into steps: {e}")
            import traceback
            traceback.print_exc()
            state["steps"] = []
        
        return state
    
    # Original logic: generate answer from chunks
    # Build context from chunks
    context_parts = []
    for chunk in chunks:
        metadata = chunk.get("metadata", {})
        meta_parts = []
        if metadata.get("title"):
            meta_parts.append(f"Section: {metadata['title']}")
        if metadata.get("page"):
            meta_parts.append(f"Page: {metadata['page']}")
        if metadata.get("chapter"):
            meta_parts.append(f"Chapter: {metadata['chapter']}")
        
        chunk_text = chunk["content"]
        if meta_parts:
            chunk_text = f"[{', '.join(meta_parts)}]\n\n{chunk_text}"
        context_parts.append(chunk_text)
    
    context = "\n\n---\n\n".join(context_parts)
    
    if not client:
        state["full_answer"] = "OpenAI client not available."
        state["steps"] = []
        return state
    
    try:
        system_prompt = f"""You are Ableton Smart Assistant. Reference Ableton documentation snippets when answering.
User's edition: {edition}
"""
        
        if not allowed and version_explanation:
            system_prompt += f"\nNote: The user is attempting something that may not be fully compatible with their edition: {version_explanation}"
        
        user_prompt = f"""User question: {query}

Documentation context:
{context}

Please provide:
1. A clear explanation of how to accomplish this task
2. A step-by-step guide in JSON format with the following structure:
{{
  "explanation": "Full explanation text",
  "steps": [
    {{
      "text": "Step description",
      "requires_click": true/false
    }}
  ]
}}

Make sure the steps are actionable and specific."""
        
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ],
            temperature=0.7,
            response_format={"type": "json_object"}
        )
        
        result = json.loads(response.choices[0].message.content)
        state["full_answer"] = result.get("explanation", "")
        
        # Parse steps
        steps = result.get("steps", [])
        # Ensure all steps have required fields
        for step in steps:
            if "requires_click" not in step:
                step["requires_click"] = False
            if "button_coords" not in step:
                step["button_coords"] = None
        
        state["steps"] = steps
        
    except Exception as e:
        print(f"Error generating answer: {e}")
        state["full_answer"] = f"Error generating answer: {str(e)}"
        state["steps"] = []
    
    return state

def wait_for_user_step_choice(state: AgentState) -> AgentState:
    """Wait for user to choose step-by-step mode"""
    full_answer = state.get("full_answer", "")
    steps = state.get("steps") or []
    user_choice = (state.get("user_choice") or "").lower()
    
    # If user already made a choice, process it
    if user_choice:
        print(f"DEBUG: wait_for_user_step_choice: user_choice already set to '{user_choice}', processing")
        
        # If user chose "no", end workflow
        if "no" in user_choice or "thanks" in user_choice or "thank you" in user_choice:
            state["action_required"] = None
            state["mode"] = "simple"
            state["response_text"] = "Okay, feel free to ask if you need help!"
            return state
        
        # If user chose "yes", proceed to step_agent
        if "yes" in user_choice or "show" in user_choice or "start" in user_choice:
            # Clear action_required so workflow continues to step_agent
            state["action_required"] = None
            return state
        
        # For other choices, clear action_required and continue
        state["action_required"] = None
        return state
    
    # No choice yet, wait for user
    state["action_required"] = "wait_step_choice"
    state["mode"] = "simple"
    
    if steps and len(steps) > 0:
        state["response_text"] = (
            f"{full_answer}\n\n"
            "Would you like me to show this step-by-step? (yes/no)"
        )
    else:
        state["response_text"] = full_answer
    
    return state

def step_agent_start(state: AgentState) -> AgentState:
    """Initialize step-by-step mode"""
    steps = state.get("steps") or []
    
    if not steps or len(steps) == 0:
        state["response_text"] = "No steps to execute."
        return state
    
    state["mode"] = "step_by_step"
    state["current_step_index"] = 0
    
    # Return first step
    first_step = steps[0]
    state["response_text"] = f"Step 1 of {len(steps)}:\n{first_step.get('text', '')}"
    
    return state

def detect_interaction_type(state: AgentState) -> AgentState:
    """Detect if current step requires a click or just user action"""
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    
    if not steps or current_index >= len(steps):
        return state
    
    current_step = steps[current_index]
    step_text = current_step.get("text") or ""
    
    if not client:
        # Simple heuristic: if step mentions "click", "button", "menu", etc.
        requires_click = any(word in step_text.lower() for word in ["click", "button", "menu", "select"]) if step_text else False
        current_step["requires_click"] = requires_click
        return state
    
    try:
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": "Analyze if this step requires clicking a button or UI element in Ableton Live. Respond with JSON: {\"requires_click\": true/false}"
                },
                {
                    "role": "user",
                    "content": f"Step: {step_text}"
                }
            ],
            temperature=0.1,
            response_format={"type": "json_object"}
        )
        
        result = json.loads(response.choices[0].message.content)
        current_step["requires_click"] = result.get("requires_click", False)
    except Exception as e:
        print(f"Error detecting interaction type: {e}")
        # Fallback heuristic
        requires_click = any(word in step_text.lower() for word in ["click", "button", "menu"]) if step_text else False
        current_step["requires_click"] = requires_click
    
    return state

def analyze_screenshot_for_button(state: AgentState) -> AgentState:
    """Analyze screenshot to find button coordinates"""
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    screenshot_url = state.get("screenshot_url")
    
    if not steps or current_index >= len(steps):
        return state
    
    current_step = steps[current_index]
    step_text = current_step.get("text") or ""
    
    if not screenshot_url or not client:
        state["response_text"] = "Screenshot not provided or client unavailable."
        return state
    
    try:
        # Read image from URL (assuming it's a local file path)
        from pathlib import Path
        image_path = Path(screenshot_url)
        
        if not image_path.exists():
            state["response_text"] = "Screenshot file not found."
            return state
        
        with open(image_path, "rb") as image_file:
            image_data = image_file.read()
            image_base64 = base64.b64encode(image_data).decode('utf-8')
            
            response = client.chat.completions.create(
                model=VISION_MODEL,
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": f"Analyze the Ableton Live screenshot and find the coordinates of the button or UI element corresponding to the instruction: {step_text}\n\nReturn JSON with coordinates: {{\"x\": number, \"y\": number, \"width\": number, \"height\": number}} or {{\"found\": false}} if element not found."
                            },
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:image/png;base64,{image_base64}"
                                }
                            }
                        ]
                    }
                ],
                temperature=0.1,
                max_tokens=200
            )
        
        result_text = response.choices[0].message.content
        # Try to extract JSON from response
        json_match = re.search(r'\{[^}]+\}', result_text)
        if json_match:
            result = json.loads(json_match.group())
            if result.get("found", True) and "x" in result:
                current_step["button_coords"] = {
                    "x": result["x"],
                    "y": result["y"],
                    "width": result.get("width", 50),
                    "height": result.get("height", 50)
                }
            else:
                current_step["button_coords"] = None
        else:
            current_step["button_coords"] = None
            
    except Exception as e:
        print(f"Error analyzing screenshot: {e}")
        current_step["button_coords"] = None
    
    return state

def wait_user_action(state: AgentState) -> AgentState:
    """Wait for user action (next, skip, cancel)"""
    state["action_required"] = "wait_user_action"
    
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    
    if steps and current_index < len(steps):
        current_step = steps[current_index]
        step_text = current_step.get("text") or ""
        button_coords = current_step.get("button_coords")
        
        response_parts = [f"Step {current_index + 1} of {len(steps)}:\n{step_text}"]
        
        if button_coords:
            response_parts.append(f"\nButton coordinates: x={button_coords.get('x', 0)}, y={button_coords.get('y', 0)}")
        
        state["response_text"] = "\n".join(response_parts)
    else:
        state["response_text"] = "All steps completed."
    
    return state

def optional_validate_step(state: AgentState) -> AgentState:
    """Optionally validate if step was completed correctly"""
    steps = state.get("steps", [])
    current_index = state.get("current_step_index", 0)
    screenshot_url = state.get("screenshot_url")
    user_choice = state.get("user_choice") or ""
    
    if current_index >= len(steps):
        return state
    
    current_step = steps[current_index]
    
    # Skip validation if user chose to skip
    user_choice_lower = user_choice.lower() if user_choice else ""
    if "skip" in user_choice_lower:
        return state
    
    # Only validate if step requires click
    if not current_step.get("requires_click", False):
        return state
    
    if not screenshot_url or not client:
        return state
    
    step_text = current_step.get("text") or ""
    
    try:
        from pathlib import Path
        image_path = Path(screenshot_url)
        
        if not image_path.exists():
            return state
        
        with open(image_path, "rb") as image_file:
            image_data = image_file.read()
            image_base64 = base64.b64encode(image_data).decode('utf-8')
            
            response = client.chat.completions.create(
                model=VISION_MODEL,
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": f"Do you see the state after completing the step: {step_text}? Return JSON: {{\"valid\": true/false, \"explanation\": \"brief explanation\"}}"
                            },
                            {
                                "type": "image_url",
                                "image_url": {
                                    "url": f"data:image/png;base64,{image_base64}"
                                }
                            }
                        ]
                    }
                ],
                temperature=0.1,
                max_tokens=200
            )
        
        result_text = response.choices[0].message.content
        json_match = re.search(r'\{[^}]+\}', result_text)
        if json_match:
            result = json.loads(json_match.group())
            if not result.get("valid", True):
                explanation = result.get("explanation", "Step was not completed correctly.")
                state["response_text"] = f"⚠️ {explanation}"
    except Exception as e:
        print(f"Error validating step: {e}")
    
    return state

def next_step_or_finish(state: AgentState) -> AgentState:
    """Move to next step or finish"""
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    
    if steps and current_index < len(steps) - 1:
        state["current_step_index"] = current_index + 1
        # Will continue to detect_interaction_type
    else:
        # All steps done, mark for final confirmation
        # Don't set response_text here - it will be set in final_confirmation
        # Just mark that we need final confirmation
        state["action_required"] = "wait_task_completion_choice"
    
    return state

def final_confirmation(state: AgentState) -> AgentState:
    """Final confirmation if task was solved - show question on last step"""
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    user_query = state.get("user_query", "")
    
    # Detect language from user query
    query_lang = detect_language(user_query)
    
    # Language-specific messages
    completion_questions = {
        "ru": "Did you manage to solve the task?",
        "en": "Did you manage to solve the task?"
    }
    completion_question = completion_questions.get(query_lang, completion_questions["en"])
    
    # If we have steps and we're on the last one, show last step + question
    if steps and current_index < len(steps):
        last_step = steps[current_index]
        last_step_text = last_step.get("text", "")
        total_steps = len(steps)
        step_number = current_index + 1
        
        # Add step header with number
        step_header = f"Step {step_number} of {total_steps}:"
        
        # Combine step header + last step + completion question
        state["response_text"] = f"{step_header}\n{last_step_text}\n\n{completion_question}"
        
        state["action_required"] = "wait_task_completion_choice"
    else:
        # No steps or already past last step, just show question
        state["response_text"] = completion_question
        state["action_required"] = "wait_task_completion_choice"
    
    return state

def fallback_review_steps(state: AgentState) -> AgentState:
    """Review all steps to find which ones weren't completed"""
    steps = state.get("steps", [])
    query = state["user_query"]
    
    if not client:
        state["response_text"] = "Failed to analyze steps."
        return state
    
    try:
        steps_text = "\n".join([f"{i+1}. {step['text']}" for i, step in enumerate(steps)])
        
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            messages=[
                {
                    "role": "system",
                    "content": "Analyze which steps from the list were likely not completed. Return JSON with problematic step indices (0-based): {\"problematic_steps\": [0, 2, ...]}"
                },
                {
                    "role": "user",
                    "content": f"Original task: {query}\n\nSteps:\n{steps_text}"
                }
            ],
            temperature=0.3,
            response_format={"type": "json_object"}
        )
        
        result = json.loads(response.choices[0].message.content)
        problematic = result.get("problematic_steps", [])
        
        if problematic:
            first_problematic = problematic[0]
            state["current_step_index"] = first_problematic
            state["mode"] = "step_by_step"
            state["response_text"] = f"Let's start from step {first_problematic + 1}."
        else:
            state["response_text"] = "All steps completed correctly."
    except Exception as e:
        print(f"Error in fallback review: {e}")
        state["response_text"] = "Failed to identify problematic steps."
    
    return state
