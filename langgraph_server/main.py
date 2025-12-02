"""FastAPI application for LangGraph agent"""
import uuid
from typing import List, Optional
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Support both relative imports (for LangGraph Studio) and absolute imports (for direct uvicorn run)
try:
    from .workflow import create_workflow
    from .state import AgentState
except ImportError:
    from workflow import create_workflow
    from state import AgentState

app = FastAPI(title="LangGraph Agent API")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify actual origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# In-memory session storage
sessions: dict[str, dict] = {}

# Create workflow
workflow = create_workflow()

# Request/Response models
class ConversationEntry(BaseModel):
    role: str  # "user" | "assistant" | "system"
    text: str
    screenshot_url: Optional[str] = None

class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None
    history: List[ConversationEntry]
    ableton_edition: str
    screenshot_url: Optional[str] = None

class StepByStepRequest(BaseModel):
    message: str
    rag_answer: str  # Pre-generated answer from RAGStore
    session_id: Optional[str] = None
    history: List[ConversationEntry]
    ableton_edition: str
    screenshot_url: Optional[str] = None

class ChatResponse(BaseModel):
    response: str
    session_id: str
    mode: str  # "simple" | "step_by_step"
    steps: Optional[List[dict]] = None
    action_required: Optional[str] = None

class StepRequest(BaseModel):
    session_id: str
    user_action: str  # "next" | "skip" | "cancel" | custom text
    screenshot_url: Optional[str] = None

class StepResponse(BaseModel):
    step_text: str
    step_index: int
    total_steps: int
    requires_click: bool
    button_coords: Optional[dict] = None
    action_required: Optional[str] = None

class ValidateStepRequest(BaseModel):
    session_id: str
    screenshot_url: str
    step_index: int

class ValidateStepResponse(BaseModel):
    valid: bool
    explanation: Optional[str] = None

class SessionStatusResponse(BaseModel):
    mode: str
    current_step: Optional[int] = None
    total_steps: Optional[int] = None
    current_step_info: Optional[dict] = None  # Current step details including requires_click

def convert_history_to_state(history: List[ConversationEntry]) -> List[dict]:
    """Convert conversation history to state format"""
    return [
        {
            "role": entry.role,
            "text": entry.text,
            "screenshot_url": entry.screenshot_url
        }
        for entry in history
    ]

@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """Main endpoint for processing chat messages"""
    # Generate or use session_id
    session_id = request.session_id or str(uuid.uuid4())
    
    # Initialize or get session state
    if session_id not in sessions:
        sessions[session_id] = {
            "session_id": session_id,
            "user_query": request.message,
            "ableton_edition": request.ableton_edition,
            "conversation_history": convert_history_to_state(request.history),
            "screenshot_url": request.screenshot_url,
            "intent": None,
            "allowed": None,
            "version_explanation": None,
            "selected_chunks": [],
            "full_answer": None,
            "steps": [],
            "current_step_index": 0,
            "mode": "simple",
            "user_choice": None,
            "action_required": None,
            "response_text": None
        }
    else:
        # Update session with new message
        action_required = sessions[session_id].get("action_required")
        
        # Special handling for "show_button" message
        if request.message.lower() == "show_button" and request.screenshot_url:
            # User wants to see button location, trigger analyze_screenshot
            sessions[session_id]["screenshot_url"] = request.screenshot_url
            sessions[session_id]["conversation_history"] = convert_history_to_state(request.history)
            sessions[session_id]["ableton_edition"] = request.ableton_edition
            # Don't update user_query, keep original
            # Trigger analyze_screenshot directly
            try:
                from . import nodes
            except ImportError:
                import nodes
            state: AgentState = {
                "session_id": sessions[session_id]["session_id"],
                "user_query": sessions[session_id].get("user_query", ""),
                "ableton_edition": sessions[session_id].get("ableton_edition", ""),
                "conversation_history": convert_history_to_state(request.history),
                "screenshot_url": request.screenshot_url,
                "intent": sessions[session_id].get("intent"),
                "allowed": sessions[session_id].get("allowed"),
                "version_explanation": sessions[session_id].get("version_explanation"),
                "selected_chunks": sessions[session_id].get("selected_chunks", []),
                "full_answer": sessions[session_id].get("full_answer"),
                "steps": sessions[session_id].get("steps", []),
                "current_step_index": sessions[session_id].get("current_step_index", 0),
                "mode": sessions[session_id].get("mode", "step_by_step"),
                "user_choice": None,
                "action_required": "wait_user_action",
                "response_text": None
            }
            # Analyze screenshot for button
            result = nodes.analyze_screenshot_for_button(state)
            sessions[session_id].update(result)
            
            # Prepare response
            steps = result.get("steps", [])
            current_index = result.get("current_step_index", 0)
            response_text = "Button found! See the highlight on screen."
            if steps and current_index < len(steps):
                current_step = steps[current_index]
                if current_step.get("button_coords"):
                    coords = current_step["button_coords"]
                    response_text = f"Button found at coordinates: x={coords.get('x')}, y={coords.get('y')}"
            
            return ChatResponse(
                response=response_text,
                session_id=session_id,
                mode="step_by_step",
                steps=steps,
                action_required="wait_user_action"
            )
        
        # If we're waiting for a step choice or version choice, treat the message as user_choice
        # Don't update user_query in this case - keep the original query
        if action_required == "wait_step_choice" or action_required == "wait_version_choice":
            sessions[session_id]["user_choice"] = request.message
            print(f"DEBUG: Setting user_choice='{request.message}' for {action_required}, keeping original user_query")
        else:
            # This is a new query, update user_query
            sessions[session_id]["user_query"] = request.message
        
        # Update these fields in any case
        sessions[session_id]["conversation_history"] = convert_history_to_state(request.history)
        sessions[session_id]["screenshot_url"] = request.screenshot_url
        sessions[session_id]["ableton_edition"] = request.ableton_edition
    
    # Get current state
    state = sessions[session_id]
    
    # Run workflow
    try:
        # Create initial state for workflow
        initial_state: AgentState = {
            "session_id": state["session_id"],
            "user_query": state["user_query"],
            "ableton_edition": state["ableton_edition"],
            "conversation_history": state["conversation_history"],
            "screenshot_url": state.get("screenshot_url"),
            "intent": state.get("intent"),
            "allowed": state.get("allowed"),
            "version_explanation": state.get("version_explanation"),
            "selected_chunks": state.get("selected_chunks", []),
            "full_answer": state.get("full_answer"),
            "steps": state.get("steps", []),
            "current_step_index": state.get("current_step_index", 0),
            "mode": state.get("mode", "simple"),
            "user_choice": state.get("user_choice"),
            "action_required": state.get("action_required"),
            "response_text": state.get("response_text")
        }
        
        # Run workflow step by step until it reaches an action_required or end
        result = initial_state
        max_iterations = 20  # Safety limit
        iteration = 0
        
        try:
            # Ensure all list fields are initialized
            if "steps" not in initial_state or initial_state["steps"] is None:
                initial_state["steps"] = []
            if "selected_chunks" not in initial_state or initial_state["selected_chunks"] is None:
                initial_state["selected_chunks"] = []
            if "conversation_history" not in initial_state or initial_state["conversation_history"] is None:
                initial_state["conversation_history"] = []
            
            for step in workflow.stream(initial_state):
                iteration += 1
                # Get the last state from the stream
                # step is a dict with node names as keys
                for node_name, node_state in step.items():
                    result = node_state
                    # Ensure steps is always a list, not None
                    if "steps" in result and result["steps"] is None:
                        result["steps"] = []
                    if "selected_chunks" in result and result["selected_chunks"] is None:
                        result["selected_chunks"] = []
                    # Stop if we reach a node that requires user action
                    if result.get("action_required"):
                        print(f"DEBUG: Stopping workflow at node '{node_name}' with action_required={result.get('action_required')}")
                        break
                # Stop if we have action_required or reached max iterations
                if result.get("action_required") or iteration >= max_iterations:
                    break
        except Exception as e:
            print(f"ERROR in workflow execution: {e}")
            import traceback
            traceback.print_exc()
            raise
        
        # Update session with result
        sessions[session_id].update(result)
        
        # Prepare response
        response_text = result.get("response_text") or result.get("full_answer") or "No response generated."
        mode = result.get("mode", "simple")
        steps_list = result.get("steps") or []
        steps = steps_list if mode == "step_by_step" and steps_list else None
        action_required = result.get("action_required")
        
        # Debug logging
        response_length = len(response_text) if response_text else 0
        print(f"DEBUG: Workflow result - action_required={action_required}, mode={mode}, steps_count={len(steps_list)}, response_length={response_length}")
        
        return ChatResponse(
            response=response_text,
            session_id=session_id,
            mode=mode,
            steps=steps,
            action_required=action_required
        )
    except Exception as e:
        import traceback
        error_details = traceback.format_exc()
        print(f"ERROR in /chat endpoint: {e}")
        print(error_details)
        raise HTTPException(status_code=500, detail=f"Error processing request: {str(e)}")

@app.post("/step", response_model=StepResponse)
async def step(request: StepRequest):
    """Handle step action in step-by-step mode"""
    if request.session_id not in sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    
    session = sessions[request.session_id]
    
    # Update user choice
    session["user_choice"] = request.user_action
    if request.screenshot_url:
        session["screenshot_url"] = request.screenshot_url
    
    # Get current step info
    steps = session.get("steps", [])
    current_index = session.get("current_step_index", 0)
    
    if current_index >= len(steps):
        raise HTTPException(status_code=400, detail="No more steps")
    
    current_step = steps[current_index]
    
    # Handle action
    if "cancel" in request.user_action.lower():
        return StepResponse(
            step_text="Task cancelled.",
            step_index=current_index,
            total_steps=len(steps),
            requires_click=False,
            button_coords=None,
            action_required=None
        )
    
    # Continue workflow from wait_action node
    try:
        state: AgentState = {
            "session_id": session["session_id"],
            "user_query": session.get("user_query", ""),
            "ableton_edition": session.get("ableton_edition", ""),
            "conversation_history": session.get("conversation_history", []),
            "screenshot_url": session.get("screenshot_url"),
            "intent": session.get("intent"),
            "allowed": session.get("allowed"),
            "version_explanation": session.get("version_explanation"),
            "selected_chunks": session.get("selected_chunks", []),
            "full_answer": session.get("full_answer"),
            "steps": steps,
            "current_step_index": current_index,
            "mode": "step_by_step",
            "user_choice": request.user_action,
            "action_required": session.get("action_required"),
            "response_text": None
        }
        
        # Continue from validate or next_step
        try:
            from . import nodes
        except ImportError:
            import nodes
        
        print(f"DEBUG: /step - current_index={current_index}, total_steps={len(steps)}, action={request.user_action}")
        
        if "skip" in request.user_action.lower():
            # Skip validation, go directly to next_step
            result = nodes.next_step_or_finish(state)
        else:
            # For "next" action, run validation then next_step
            state = nodes.optional_validate_step(state)
            result = nodes.next_step_or_finish(state)
        
        # Update session with result (this includes updated current_step_index)
        sessions[request.session_id].update(result)
        
        # Check if we're handling task completion choice
        action_required = result.get("action_required")
        if action_required == "wait_task_completion_choice":
            # User is responding to completion question
            user_choice_lower = request.user_action.lower()
            user_query = session.get("user_query", "")
            
            # Detect language
            query_lang = nodes.detect_language(user_query)
            
            # Check if user said "yes" or "no"
            yes_keywords = ["yes", "solved", "done", "completed", "finished", "managed", "succeeded"]
            no_keywords = ["no", "failed", "didn't", "couldn't", "unable", "not solved"]
            
            is_yes = any(keyword in user_choice_lower for keyword in yes_keywords)
            is_no = any(keyword in user_choice_lower for keyword in no_keywords)
            
            if is_yes:
                # Task completed successfully
                completion_messages = {
                    "ru": "Great! Task completed. If you need help with anything else, just ask!",
                    "en": "Great! Task completed. If you need help with anything else, just ask!"
                }
                completion_msg = completion_messages.get(query_lang, completion_messages["en"])
                
                sessions[request.session_id]["action_required"] = None
                sessions[request.session_id]["mode"] = "simple"
                return StepResponse(
                    step_text=completion_msg,
                    step_index=len(steps) - 1,
                    total_steps=len(steps),
                    requires_click=False,
                    button_coords=None,
                    action_required=None
                )
            elif is_no:
                # Task not completed, restart from first step
                restart_messages = {
                    "ru": "Let's start over from the first step.",
                    "en": "Let's start over from the first step."
                }
                restart_msg = restart_messages.get(query_lang, restart_messages["en"])
                
                # Reset to first step
                sessions[request.session_id]["current_step_index"] = 0
                sessions[request.session_id]["action_required"] = "wait_user_action"
                
                # Get first step
                first_step = steps[0]
                first_step_text = f"Step 1 of {len(steps)}:\n{first_step.get('text', '')}"
                
                result = nodes.detect_interaction_type({
                    **sessions[request.session_id],
                    "steps": steps,
                    "current_step_index": 0
                })
                sessions[request.session_id].update(result)
                
                return StepResponse(
                    step_text=first_step_text,
                    step_index=0,
                    total_steps=len(steps),
                    requires_click=first_step.get("requires_click", False),
                    button_coords=first_step.get("button_coords"),
                    action_required="wait_user_action"
                )
            else:
                # Unclear response, ask again
                query_messages = {
                    "ru": "Please answer 'Yes' or 'No'. Did you manage to solve the task?",
                    "en": "Please answer 'Yes' or 'No'. Did you manage to solve the task?"
                }
                query_msg = query_messages.get(query_lang, query_messages["en"])
                
                # Show last step + question again with step header
                last_step = steps[-1]
                last_step_text = last_step.get("text", "")
                completion_questions = {
                    "ru": "Did you manage to solve the task?",
                    "en": "Did you manage to solve the task?"
                }
                completion_question = completion_questions.get(query_lang, completion_questions["en"])
                step_header = f"Step {len(steps)} of {len(steps)}:"
                
                return StepResponse(
                    step_text=f"{step_header}\n{last_step_text}\n\n{completion_question}",
                    step_index=len(steps) - 1,
                    total_steps=len(steps),
                    requires_click=False,
                    button_coords=None,
                    action_required="wait_task_completion_choice"
                )
        
        # Get next step if available - use the updated index from result
        new_index = result.get("current_step_index", current_index)
        print(f"DEBUG: /step - After next_step_or_finish: new_index={new_index}, len(steps)={len(steps)}, current_index was={current_index}")
        
        # Double-check that session was updated
        session_after_update = sessions[request.session_id]
        session_index = session_after_update.get("current_step_index", 0)
        print(f"DEBUG: /step - Session index after update: {session_index}")
        
        # If index didn't change, something went wrong
        if new_index == current_index and current_index < len(steps) - 1:
            print(f"WARNING: /step - Index didn't increase! current={current_index}, new={new_index}, total={len(steps)}")
            # Force increment
            new_index = current_index + 1
            result["current_step_index"] = new_index
            sessions[request.session_id]["current_step_index"] = new_index
        
        # Check if we're on the last step
        if new_index == len(steps) - 1:
            # Last step - show it with completion question
            result = nodes.final_confirmation(result)
            sessions[request.session_id].update(result)
            
            response_text = result.get("response_text", "")
            print(f"DEBUG: /step - Last step response_text length: {len(response_text)}")
            
            return StepResponse(
                step_text=response_text,
                step_index=new_index,
                total_steps=len(steps),
                requires_click=False,
                button_coords=None,
                action_required="wait_task_completion_choice"
            )
        elif new_index < len(steps) and new_index >= 0:
            # We have more steps, continue to detect_interaction_type for the new step
            result = nodes.detect_interaction_type(result)
            
            # If requires click, we might need screenshot, but for now just return the step
            # User can click "Show the button" if needed
            next_step = steps[new_index]
            
            # Use English for step prefix (UI is always in English)
            step_text = f"Step {new_index + 1} of {len(steps)}:\n{next_step.get('text', '')}"
            
            # Update session again with interaction type
            sessions[request.session_id].update(result)
            
            print(f"DEBUG: /step - Returning step {new_index + 1}: {step_text[:100]}...")
            return StepResponse(
                step_text=step_text,
                step_index=new_index,
                total_steps=len(steps),
                requires_click=next_step.get("requires_click", False),
                button_coords=next_step.get("button_coords"),
                action_required="wait_user_action"
            )
        else:
            # Should not reach here, but handle gracefully
            print(f"DEBUG: /step - Unexpected state (new_index={new_index}, total={len(steps)})")
            sessions[request.session_id]["action_required"] = None
            sessions[request.session_id]["mode"] = "simple"
            return StepResponse(
                step_text="All steps completed.",
                step_index=len(steps) - 1,
                total_steps=len(steps),
                requires_click=False,
                button_coords=None,
                action_required=None
            )
    except Exception as e:
        import traceback
        error_details = traceback.format_exc()
        print(f"ERROR in /step endpoint: {e}")
        print(error_details)
        raise HTTPException(status_code=500, detail=f"Error processing step: {str(e)}")

@app.post("/step/validate", response_model=ValidateStepResponse)
async def validate_step(request: ValidateStepRequest):
    """Validate if a step was completed correctly"""
    if request.session_id not in sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    
    session = sessions[request.session_id]
    steps = session.get("steps", [])
    
    if request.step_index >= len(steps):
        raise HTTPException(status_code=400, detail="Invalid step index")
    
    step = steps[request.step_index]
    step_text = step.get("text", "")
    
    # Use vision API to validate
    try:
        try:
            from . import nodes
        except ImportError:
            import nodes
        
        state: AgentState = {
            "session_id": session["session_id"],
            "user_query": session.get("user_query", ""),
            "ableton_edition": session.get("ableton_edition", ""),
            "conversation_history": session.get("conversation_history", []),
            "screenshot_url": request.screenshot_url,
            "intent": session.get("intent"),
            "allowed": session.get("allowed"),
            "version_explanation": session.get("version_explanation"),
            "selected_chunks": session.get("selected_chunks", []),
            "full_answer": session.get("full_answer"),
            "steps": steps,
            "current_step_index": request.step_index,
            "mode": "step_by_step",
            "user_choice": None,
            "action_required": None,
            "response_text": None
        }
        
        result = nodes.optional_validate_step(state)
        response_text = result.get("response_text", "")
        
        # Parse validation result from response_text
        valid = not response_text.startswith("⚠️") if response_text else True
        explanation = response_text if not valid else None
        
        return ValidateStepResponse(
            valid=valid,
            explanation=explanation
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error validating step: {str(e)}")

@app.get("/session/{session_id}/status", response_model=SessionStatusResponse)
async def get_session_status(session_id: str):
    """Get current status of a session"""
    if session_id not in sessions:
        raise HTTPException(status_code=404, detail="Session not found")
    
    session = sessions[session_id]
    mode = session.get("mode", "simple")
    current_step = session.get("current_step_index")
    steps = session.get("steps", [])
    total_steps = len(steps) if steps else None
    
    # Get current step info if available
    current_step_info = None
    if mode == "step_by_step" and steps and current_step is not None and current_step < len(steps):
        current_step_info = steps[current_step]
    
    return SessionStatusResponse(
        mode=mode,
        current_step=current_step if mode == "step_by_step" else None,
        total_steps=total_steps if mode == "step_by_step" else None,
        current_step_info=current_step_info
    )

@app.post("/chat/step-by-step", response_model=ChatResponse)
async def chat_step_by_step(request: StepByStepRequest):
    """Start step-by-step mode with existing RAG answer (skips nodes 1-4)"""
    # Generate or use session_id
    session_id = request.session_id or str(uuid.uuid4())
    
    # Initialize session state with RAG answer
    if session_id not in sessions:
        sessions[session_id] = {
            "session_id": session_id,
            "user_query": request.message,
            "ableton_edition": request.ableton_edition,
            "conversation_history": convert_history_to_state(request.history),
            "screenshot_url": request.screenshot_url,
            "intent": "ableton_question",  # Skip intent detection
            "allowed": True,  # Skip version check
            "version_explanation": None,
            "selected_chunks": [],  # Skip RAG retrieval
            "full_answer": request.rag_answer,  # Use provided RAG answer
            "steps": [],
            "current_step_index": 0,
            "mode": "simple",
            "user_choice": None,
            "action_required": None,
            "response_text": None
        }
    else:
        # Update existing session
        sessions[session_id]["user_query"] = request.message
        sessions[session_id]["full_answer"] = request.rag_answer
        sessions[session_id]["conversation_history"] = convert_history_to_state(request.history)
        sessions[session_id]["screenshot_url"] = request.screenshot_url
        sessions[session_id]["ableton_edition"] = request.ableton_edition
        # Skip nodes 1-4, so set these to skip checks
        sessions[session_id]["intent"] = "ableton_question"
        sessions[session_id]["allowed"] = True
    
    # Get current state
    state = sessions[session_id]
    
    # Run workflow starting from generate_answer node
    try:
        initial_state: AgentState = {
            "session_id": state["session_id"],
            "user_query": state["user_query"],
            "ableton_edition": state["ableton_edition"],
            "conversation_history": state["conversation_history"],
            "screenshot_url": state.get("screenshot_url"),
            "intent": "ableton_question",  # Already determined
            "allowed": True,  # Already checked
            "version_explanation": None,
            "selected_chunks": [],  # Not needed, we have full_answer
            "full_answer": state["full_answer"],
            "steps": state.get("steps", []),
            "current_step_index": state.get("current_step_index", 0),
            "mode": state.get("mode", "simple"),
            "user_choice": state.get("user_choice"),
            "action_required": state.get("action_required"),
            "response_text": None
        }
        
        # Ensure all list fields are initialized
        if "steps" not in initial_state or initial_state["steps"] is None:
            initial_state["steps"] = []
        if "selected_chunks" not in initial_state or initial_state["selected_chunks"] is None:
            initial_state["selected_chunks"] = []
        if "conversation_history" not in initial_state or initial_state["conversation_history"] is None:
            initial_state["conversation_history"] = []
        
        # Start workflow from generate_answer node
        # We need to manually call nodes starting from generate_answer
        try:
            from . import nodes
        except ImportError:
            import nodes
        
        # Start from generate_answer (node 5) - it will use existing full_answer
        full_answer_in_state = initial_state.get('full_answer', '')
        print(f"DEBUG: /chat/step-by-step - full_answer length: {len(full_answer_in_state)}")
        print(f"DEBUG: /chat/step-by-step - full_answer preview (first 300 chars): {full_answer_in_state[:300]}")
        print(f"DEBUG: /chat/step-by-step - request.rag_answer length: {len(request.rag_answer)}")
        print(f"DEBUG: /chat/step-by-step - request.rag_answer preview (first 300 chars): {request.rag_answer[:300]}")
        print(f"DEBUG: /chat/step-by-step - full_answer matches request.rag_answer: {full_answer_in_state == request.rag_answer}")
        
        result = nodes.generate_full_answer(initial_state)
        
        # Verify that full_answer was preserved
        result_full_answer = result.get('full_answer', '')
        print(f"DEBUG: /chat/step-by-step - After generate_full_answer, full_answer preserved: {result_full_answer == request.rag_answer}")
        print(f"DEBUG: /chat/step-by-step - Result full_answer length: {len(result_full_answer)}")
        
        # Check if we have steps
        steps = result.get("steps", [])
        print(f"DEBUG: /chat/step-by-step - extracted {len(steps)} steps")
        if not steps or len(steps) == 0:
            # No steps extracted, return error with more info
            full_answer = result.get("full_answer", "")
            error_msg = f"Failed to extract steps from answer. Answer length: {len(full_answer)} characters. Please try again."
            print(f"DEBUG: /chat/step-by-step - ERROR: {error_msg}")
            return ChatResponse(
                response=error_msg,
                session_id=session_id,
                mode="simple",
                steps=None,
                action_required=None
            )
        
        # User already clicked "Start step-by-step", so skip wait_step_choice
        # Go directly to step_agent_start
        result = nodes.step_agent_start(result)
        result = nodes.detect_interaction_type(result)
        
        # If requires click, we'll wait for screenshot (user will click "Show the button")
        # For now, just go to wait_action
        result = nodes.wait_user_action(result)
        
        # Update session with result
        sessions[session_id].update(result)
        
        # Prepare response - use response_text from wait_user_action, or construct from first step
        response_text = result.get("response_text")
        if not response_text:
            # Fallback: construct response from first step
            steps_list = result.get("steps", [])
            if steps_list and len(steps_list) > 0:
                first_step = steps_list[0]
                response_text = f"Step 1 of {len(steps_list)}:\n{first_step.get('text', '')}"
            else:
                response_text = result.get("full_answer") or "Failed to extract steps from answer."
        mode = result.get("mode", "simple")
        steps_list = result.get("steps") or []
        steps = steps_list if mode == "step_by_step" and steps_list else None
        action_required = result.get("action_required")
        
        print(f"DEBUG: Step-by-step result - action_required={action_required}, mode={mode}, steps_count={len(steps_list)}, response_length={len(response_text)}")
        
        return ChatResponse(
            response=response_text,
            session_id=session_id,
            mode=mode,
            steps=steps,
            action_required=action_required
        )
    except Exception as e:
        import traceback
        error_details = traceback.format_exc()
        print(f"ERROR in /chat/step-by-step endpoint: {e}")
        print(error_details)
        raise HTTPException(status_code=500, detail=f"Error processing step-by-step request: {str(e)}")

@app.get("/health")
async def health():
    """Health check endpoint"""
    return {"status": "ok"}

if __name__ == "__main__":
    import uvicorn
    try:
        from .config import SERVER_HOST, SERVER_PORT
    except ImportError:
        from config import SERVER_HOST, SERVER_PORT
    uvicorn.run(app, host=SERVER_HOST, port=SERVER_PORT)
