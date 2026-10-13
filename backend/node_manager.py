"""
Synaps Filesystem Node Manager.
Maintains the adjacency tree in `filesystem_nodes` for fast O(1) folder navigation.
"""
import os
import re
from typing import List, Optional
from sqlalchemy.orm import Session
from models_v2 import FilesystemNode, Source


def split_original_path(original_path: str, platform: str) -> List[str]:
    """
    Split an authoritative original path into sequential hierarchy parts.
    Examples:
      Windows "E:\\Himachal\\2025\\IMG001.jpg" -> ["E:", "Himachal", "2025", "IMG001.jpg"]
      Mac "/Users/harshrathod/Downloads/AWS/practical4.pdf" -> ["Downloads", "AWS", "practical4.pdf"]
      iPhone "Camera Roll/Somnath Trip/IMG_9821.HEIC" -> ["Camera Roll", "Somnath Trip", "IMG_9821.HEIC"]
    """
    clean_path = original_path.replace("\\", "/").strip("/")

    if platform.lower() == "windows":
        parts = clean_path.split("/")
        # If first part is drive e.g. "E:", keep it
        return [p for p in parts if p]

    elif platform.lower() in ("macos", "darwin"):
        parts = clean_path.split("/")
        # If starts with Users/<username>/..., strip down to the meaningful user folder
        if len(parts) >= 3 and parts[0].lower() == "users":
            parts = parts[2:]
        return [p for p in parts if p]

    # Default
    return [p for p in clean_path.split("/") if p]


def get_or_create_node_path(
    db: Session,
    source_id: str,
    original_path: str,
    platform: str,
    physical_object_id: Optional[str] = None
) -> FilesystemNode:
    """
    Recursively builds or resolves the node tree hierarchy for a path.
    The final component is marked as is_directory=False with physical_object_id set.
    Returns the leaf FilesystemNode.
    """
    parts = split_original_path(original_path, platform)
    if not parts:
        parts = [os.path.basename(original_path) or "unknown_file"]

    current_parent_id = None
    node = None

    for i, part in enumerate(parts):
        is_leaf = (i == len(parts) - 1)
        is_dir = not is_leaf

        # Check if node already exists
        existing_node = (
            db.query(FilesystemNode)
            .filter(
                FilesystemNode.source_id == source_id,
                FilesystemNode.parent_id == current_parent_id,
                FilesystemNode.name == part
            )
            .first()
        )

        if existing_node:
            node = existing_node
            # If it's the leaf and was previously missing physical object, update it
            if is_leaf and physical_object_id and not node.physical_object_id:
                node.physical_object_id = physical_object_id
                node.is_directory = False
        else:
            node = FilesystemNode(
                source_id=source_id,
                parent_id=current_parent_id,
                name=part,
                is_directory=is_dir,
                physical_object_id=physical_object_id if is_leaf else None
            )
            db.add(node)
            db.flush()  # Assign node.id

        current_parent_id = node.id

    return node
