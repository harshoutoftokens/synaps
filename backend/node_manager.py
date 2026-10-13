"""
Synaps Filesystem Node Manager.
Maintains the adjacency tree in `filesystem_nodes` for fast O(1) folder navigation.
"""
import os
import re
from typing import Dict, List, Optional, Tuple
from sqlalchemy.orm import Session
from models_v2 import FilesystemNode, Source

# Key in a get_or_create_node_path() cache holding the ids of nodes it created
_CREATED = ("__created__",)


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
    physical_object_id: Optional[str] = None,
    cache: Optional[Dict[Tuple[str, Optional[int], str], FilesystemNode]] = None,
) -> FilesystemNode:
    """
    Recursively builds or resolves the node tree hierarchy for a path.
    The final component is marked as is_directory=False with physical_object_id set
    (re-pointed if the file's content changed since it was last ingested).
    Returns the leaf FilesystemNode.

    `cache` (optional, per request) remembers resolved nodes so a batch of files that
    share folders doesn't re-query every path component of every file.
    """
    parts = split_original_path(original_path, platform)
    if not parts:
        parts = [os.path.basename(original_path) or "unknown_file"]

    current_parent_id = None
    node = None

    for i, part in enumerate(parts):
        is_leaf = (i == len(parts) - 1)
        is_dir = not is_leaf

        # Check if node already exists (a folder created by this same batch has no other children)
        key = (source_id, current_parent_id, part)
        existing_node = cache.get(key) if cache is not None else None
        if existing_node is None and not (cache is not None and current_parent_id in cache.get(_CREATED, ())):
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
            # Point the leaf at the file's current content (new, or changed on the source)
            if is_leaf and physical_object_id and node.physical_object_id != physical_object_id:
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
            if cache is not None:
                cache.setdefault(_CREATED, set()).add(node.id)

        if cache is not None:
            cache[key] = node
        current_parent_id = node.id

    return node
