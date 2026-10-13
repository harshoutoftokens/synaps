"""Smoke tests: the app imports, starts, and the v2 schema is registered."""
from database import Base


def test_health(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_v2_tables_registered(app):
    tables = set(Base.metadata.tables)
    for name in (
        "sources", "physical_objects", "filesystem_nodes", "logical_items",
        "albums", "album_items", "media_metadata",
    ):
        assert name in tables
