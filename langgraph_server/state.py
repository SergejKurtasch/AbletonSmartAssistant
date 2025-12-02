"""State definition for LangGraph workflow"""
from typing import TypedDict, List, Dict, Optional, Literal

class AgentState(TypedDict):
    """State for the LangGraph agent workflow"""
    session_id: str
    user_query: str
    ableton_edition: str
    conversation_history: List[Dict]  # Full history from Swift
    screenshot_url: Optional[str]  # URL to screenshot if provided
    
    # Intent detection
    intent: Optional[Literal["ableton_question", "other"]]
    
    # Version compatibility
    allowed: Optional[bool]  # Version compatibility check result
    version_explanation: Optional[str]  # Explanation if not allowed
    
    # RAG retrieval
    selected_chunks: List[Dict]  # Retrieved documentation chunks
    
    # Answer generation
    full_answer: Optional[str]  # Full generated answer
    steps: List[Dict]  # [{ "text": str, "requires_click": bool, "button_coords": dict? }]
    
    # Step-by-step mode
    mode: Literal["simple", "step_by_step"]  # Current mode
    current_step_index: int  # Current step in step-by-step mode
    user_choice: Optional[str]  # User's choice response
    
    # Action management
    action_required: Optional[
        Literal["wait_version_choice", "wait_step_choice", "wait_user_action", "wait_task_completion_choice"]
    ]  # What action is expected from user
    
    # Response text for user
    response_text: Optional[str]  # Text to show to user
