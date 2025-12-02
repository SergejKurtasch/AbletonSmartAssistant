"""LangGraph workflow definition"""
from typing import Literal
from langgraph.graph import StateGraph, END

# Support both relative imports (for LangGraph Studio) and absolute imports (for direct run)
try:
    from .state import AgentState
    from . import nodes
except ImportError:
    from state import AgentState
    import nodes

def should_continue_after_intent(state: AgentState) -> Literal["check_version", "end"]:
    """Route after intent detection"""
    if state.get("intent") == "ableton_question":
        return "check_version"
    return "end"

def should_continue_after_version_check(state: AgentState) -> Literal["wait_version_choice", "retrieve"]:
    """Route after version check"""
    if not state.get("allowed", True):
        return "wait_version_choice"
    return "retrieve"

def should_continue_after_version_choice(state: AgentState) -> Literal["retrieve", "end"]:
    """Route after version choice"""
    user_choice = (state.get("user_choice") or "").lower()
    if "new task" in user_choice or "cancel" in user_choice:
        return "end"
    return "retrieve"

def should_continue_after_step_choice(state: AgentState) -> Literal["step_agent", "end"]:
    """Route after step choice"""
    user_choice = (state.get("user_choice") or "").lower()
    if "yes" in user_choice:
        return "step_agent"
    return "end"

def should_continue_after_interaction_type(state: AgentState) -> Literal["analyze_screenshot", "wait_action"]:
    """Route after interaction type detection"""
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    
    if steps and current_index < len(steps):
        current_step = steps[current_index]
        if current_step.get("requires_click", False):
            return "analyze_screenshot"
    
    return "wait_action"

def should_continue_after_user_action(state: AgentState) -> Literal["validate", "next_step", "end"]:
    """Route after user action"""
    user_choice = (state.get("user_choice") or "").lower()
    
    if "cancel" in user_choice:
        return "end"
    
    if "skip" in user_choice:
        return "next_step"
    
    return "validate"

def should_continue_after_next_step(state: AgentState) -> Literal["detect_interaction", "final_confirmation"]:
    """Route after moving to next step"""
    steps = state.get("steps") or []
    current_index = state.get("current_step_index", 0)
    
    if steps and current_index < len(steps):
        return "detect_interaction"
    return "final_confirmation"

def should_continue_after_final_confirmation(state: AgentState) -> Literal["end", "fallback"]:
    """Route after final confirmation"""
    user_choice = (state.get("user_choice") or "").lower()
    
    if "yes" in user_choice or "solved" in user_choice or "done" in user_choice:
        return "end"
    return "fallback"

def create_workflow():
    """Create and compile the LangGraph workflow"""
    workflow = StateGraph(AgentState)
    
    # Add nodes with descriptions for LangGraph Studio visualization
    workflow.add_node("detect_intent", nodes.detect_user_intent)
    workflow.add_node("check_version", nodes.check_ableton_version)
    workflow.add_node("wait_version_choice", nodes.wait_for_version_choice)
    workflow.add_node("retrieve", nodes.retrieve_from_vectorstore)
    workflow.add_node("generate_answer", nodes.generate_full_answer)
    workflow.add_node("wait_step_choice", nodes.wait_for_user_step_choice)
    workflow.add_node("step_agent", nodes.step_agent_start)
    workflow.add_node("detect_interaction", nodes.detect_interaction_type)
    workflow.add_node("analyze_screenshot", nodes.analyze_screenshot_for_button)
    workflow.add_node("wait_action", nodes.wait_user_action)
    workflow.add_node("validate", nodes.optional_validate_step)
    workflow.add_node("next_step", nodes.next_step_or_finish)
    workflow.add_node("final_confirmation", nodes.final_confirmation)
    workflow.add_node("fallback", nodes.fallback_review_steps)
    
    # Set entry point
    workflow.set_entry_point("detect_intent")
    
    # Add conditional edges
    workflow.add_conditional_edges(
        "detect_intent",
        should_continue_after_intent,
        {
            "check_version": "check_version",
            "end": END
        }
    )
    
    workflow.add_conditional_edges(
        "check_version",
        should_continue_after_version_check,
        {
            "wait_version_choice": "wait_version_choice",
            "retrieve": "retrieve"
        }
    )
    
    workflow.add_conditional_edges(
        "wait_version_choice",
        should_continue_after_version_choice,
        {
            "retrieve": "retrieve",
            "end": END
        }
    )
    
    workflow.add_edge("retrieve", "generate_answer")
    workflow.add_edge("generate_answer", "wait_step_choice")
    
    workflow.add_conditional_edges(
        "wait_step_choice",
        should_continue_after_step_choice,
        {
            "step_agent": "step_agent",
            "end": END
        }
    )
    
    workflow.add_edge("step_agent", "detect_interaction")
    
    workflow.add_conditional_edges(
        "detect_interaction",
        should_continue_after_interaction_type,
        {
            "analyze_screenshot": "analyze_screenshot",
            "wait_action": "wait_action"
        }
    )
    
    workflow.add_edge("analyze_screenshot", "wait_action")
    
    workflow.add_conditional_edges(
        "wait_action",
        should_continue_after_user_action,
        {
            "validate": "validate",
            "next_step": "next_step",
            "end": END
        }
    )
    
    workflow.add_edge("validate", "next_step")
    
    workflow.add_conditional_edges(
        "next_step",
        should_continue_after_next_step,
        {
            "detect_interaction": "detect_interaction",
            "final_confirmation": "final_confirmation"
        }
    )
    
    workflow.add_conditional_edges(
        "final_confirmation",
        should_continue_after_final_confirmation,
        {
            "end": END,
            "fallback": "fallback"
        }
    )
    
    workflow.add_edge("fallback", "step_agent")
    
    # Compile and return
    return workflow.compile()
