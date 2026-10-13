"""
Synaps v2 Relational Provenance, Storage, and Virtual Filesystem Models.
Decouples canonical physical storage from logical device provenance.
"""
from sqlalchemy import (
    Column, String, Integer, Float, DateTime, Boolean, ForeignKey, Index, Text
)
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
import uuid

from database import Base


def generate_uuid():
    return str(uuid.uuid4())


class Source(Base):
    """Registered device source (Mac, Windows PC, iPhone, etc.)."""
    __tablename__ = "sources"

    id = Column(String, primary_key=True)  # e.g. "mac_harsh_mbp", "win_laptop_hp", "iphone_harsh"
    friendly_name = Column(String, nullable=False)
    platform = Column(String, nullable=False)  # "macOS", "Windows", "iOS"
    volume_identifier = Column(String)  # Volume UUID or Serial Number
    created_at = Column(DateTime, default=func.now())
    last_seen_at = Column(DateTime, default=func.now(), onupdate=func.now())

    # Relationships
    nodes = relationship("FilesystemNode", back_populates="source", cascade="all, delete-orphan")
    logical_items = relationship("LogicalItem", back_populates="source")
    albums = relationship("Album", back_populates="source")

    def to_dict(self):
        return {
            "id": self.id,
            "friendly_name": self.friendly_name,
            "platform": self.platform,
            "volume_identifier": self.volume_identifier,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_seen_at": self.last_seen_at.isoformat() if self.last_seen_at else None,
        }


class PhysicalObject(Base):
    """
    Immutable canonical physical file stored in the NAS Vault.
    1 PhysicalObject can be referenced by N LogicalItems across devices.
    """
    __tablename__ = "physical_objects"

    id = Column(String, primary_key=True, default=generate_uuid)
    sha256 = Column(String(64), unique=True, nullable=False, index=True)
    file_size = Column(Integer, nullable=False, default=0)
    physical_path = Column(String, nullable=False, unique=True)  # Relative to storage root
    mime_type = Column(String)
    reference_count = Column(Integer, default=1)
    created_at = Column(DateTime, default=func.now())

    # Relationships
    logical_items = relationship("LogicalItem", back_populates="physical_object")
    metadata_record = relationship("MediaMetadata", back_populates="physical_object", uselist=False, cascade="all, delete-orphan")
    nodes = relationship("FilesystemNode", back_populates="physical_object")

    def to_dict(self):
        meta = self.metadata_record.to_dict() if self.metadata_record else {}
        return {
            "id": self.id,
            "sha256": self.sha256,
            "file_size": self.file_size,
            "physical_path": self.physical_path,
            "mime_type": self.mime_type,
            "reference_count": self.reference_count,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            **meta
        }


class FilesystemNode(Base):
    """
    Adjacency-tree node representing directory hierarchy per device.
    Allows instant O(1) folder navigation without disk scans or string manipulation.
    """
    __tablename__ = "filesystem_nodes"

    id = Column(Integer, primary_key=True, autoincrement=True)
    source_id = Column(String, ForeignKey("sources.id"), nullable=False, index=True)
    parent_id = Column(Integer, ForeignKey("filesystem_nodes.id"), nullable=True, index=True)
    name = Column(String, nullable=False)
    is_directory = Column(Boolean, nullable=False, default=True)
    physical_object_id = Column(String, ForeignKey("physical_objects.id"), nullable=True, index=True)

    # Relationships
    source = relationship("Source", back_populates="nodes")
    parent = relationship("FilesystemNode", remote_side=[id], backref="children")
    physical_object = relationship("PhysicalObject", back_populates="nodes")
    logical_item = relationship("LogicalItem", back_populates="node", uselist=False)

    __table_args__ = (
        Index("idx_nodes_source_parent", "source_id", "parent_id", "name", unique=True),
    )

    def to_dict(self):
        return {
            "id": self.id,
            "source_id": self.source_id,
            "parent_id": self.parent_id,
            "name": self.name,
            "is_directory": self.is_directory,
            "physical_object_id": self.physical_object_id,
        }


class LogicalItem(Base):
    """
    Authoritative provenance of where a file originally resided.
    Never destroyed or overridden by EXIF/heuristics.
    """
    __tablename__ = "logical_items"

    id = Column(String, primary_key=True, default=generate_uuid)
    physical_object_id = Column(String, ForeignKey("physical_objects.id"), nullable=False, index=True)
    source_id = Column(String, ForeignKey("sources.id"), nullable=False, index=True)
    node_id = Column(Integer, ForeignKey("filesystem_nodes.id"), nullable=True, index=True)
    
    # Authoritative acquisition provenance
    original_path = Column(String, nullable=False, index=True)
    original_filename = Column(String, nullable=False)
    source_location = Column(String, nullable=False)  # e.g. "Downloads", "Documents", "E:", "Camera Roll"
    
    # Source timestamps
    source_created_at = Column(DateTime)
    source_modified_at = Column(DateTime)
    imported_at = Column(DateTime, default=func.now())
    is_deleted_on_source = Column(Boolean, default=False)

    # Relationships
    physical_object = relationship("PhysicalObject", back_populates="logical_items")
    source = relationship("Source", back_populates="logical_items")
    node = relationship("FilesystemNode", back_populates="logical_item")
    album_links = relationship("AlbumItem", back_populates="logical_item", cascade="all, delete-orphan")

    def to_dict(self):
        meta = self.physical_object.metadata_record.to_dict() if (self.physical_object and self.physical_object.metadata_record) else {}
        return {
            "id": self.id,
            "physical_object_id": self.physical_object_id,
            "source_id": self.source_id,
            "node_id": self.node_id,
            "original_path": self.original_path,
            "original_filename": self.original_filename,
            "source_location": self.source_location,
            "source_created_at": self.source_created_at.isoformat() if self.source_created_at else None,
            "source_modified_at": self.source_modified_at.isoformat() if self.source_modified_at else None,
            "imported_at": self.imported_at.isoformat() if self.imported_at else None,
            "file_size": self.physical_object.file_size if self.physical_object else 0,
            "sha256": self.physical_object.sha256 if self.physical_object else None,
            "physical_path": self.physical_object.physical_path if self.physical_object else None,
            **meta
        }


class Album(Base):
    """User-created albums (e.g. from iPhone Photos app or created in Synaps)."""
    __tablename__ = "albums"

    id = Column(String, primary_key=True, default=generate_uuid)
    name = Column(String, nullable=False, index=True)
    source_id = Column(String, ForeignKey("sources.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=func.now())

    # Relationships
    source = relationship("Source", back_populates="albums")
    items = relationship("AlbumItem", back_populates="album", cascade="all, delete-orphan")

    def to_dict(self):
        return {
            "id": self.id,
            "name": self.name,
            "source_id": self.source_id,
            "item_count": len(self.items) if self.items else 0,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class AlbumItem(Base):
    """Membership link between an Album and a LogicalItem."""
    __tablename__ = "album_items"

    id = Column(Integer, primary_key=True, autoincrement=True)
    album_id = Column(String, ForeignKey("albums.id"), nullable=False, index=True)
    logical_item_id = Column(String, ForeignKey("logical_items.id"), nullable=False, index=True)
    added_at = Column(DateTime, default=func.now())

    # Relationships
    album = relationship("Album", back_populates="items")
    logical_item = relationship("LogicalItem", back_populates="album_links")

    __table_args__ = (
        Index("idx_album_item_unique", "album_id", "logical_item_id", unique=True),
    )


class MediaMetadata(Base):
    """Detailed visual/media metadata linked to a PhysicalObject."""
    __tablename__ = "media_metadata"

    physical_object_id = Column(String, ForeignKey("physical_objects.id"), primary_key=True)
    capture_date = Column(DateTime, index=True)
    media_type = Column(String, nullable=False, index=True)  # image, video, document
    camera_make = Column(String)
    camera_model = Column(String)
    width = Column(Integer)
    height = Column(Integer)
    duration = Column(Float)
    is_screenshot = Column(Boolean, default=False, index=True)
    is_screen_recording = Column(Boolean, default=False)
    is_favorite = Column(Boolean, default=False, index=True)
    gps_lat = Column(Float)
    gps_lon = Column(Float)
    has_thumbnail = Column(Boolean, default=False)
    thumbnail_path = Column(String)

    # Relationship
    physical_object = relationship("PhysicalObject", back_populates="metadata_record")

    def to_dict(self):
        return {
            "capture_date": self.capture_date.isoformat() if self.capture_date else None,
            "media_type": self.media_type,
            "camera_make": self.camera_make,
            "camera_model": self.camera_model,
            "width": self.width,
            "height": self.height,
            "duration": self.duration,
            "is_screenshot": self.is_screenshot,
            "is_screen_recording": self.is_screen_recording,
            "is_favorite": self.is_favorite,
            "gps_lat": self.gps_lat,
            "gps_lon": self.gps_lon,
            "has_thumbnail": self.has_thumbnail,
            "thumbnail_path": self.thumbnail_path,
        }
