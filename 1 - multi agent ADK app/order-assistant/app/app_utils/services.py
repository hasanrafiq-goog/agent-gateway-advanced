# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Process-wide ADK session/artifact services shared by every serving surface.

Registered under ``shared://`` so the ADK web routes, the A2A path, and the
reasoning_engine adapter share one instance: a session created on any surface
is visible to the others.
"""

from __future__ import annotations

import functools
import os

from google.adk.artifacts import GcsArtifactService, InMemoryArtifactService
from google.adk.cli.service_registry import get_service_registry
from google.adk.cli.utils.service_factory import create_session_service_from_options
from google.adk.sessions.base_session_service import BaseSessionService
from google.adk.sessions.in_memory_session_service import InMemorySessionService

SESSION_SERVICE_URI = "shared://session"
ARTIFACT_SERVICE_URI = "shared://artifact"

_AGENT_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)


class ResilientSessionService(BaseSessionService):
    """Session service that attempts VertexAiSessionService first, but seamlessly
    falls back to InMemorySessionService if Vertex AI Sessions API encounters auth/network errors."""

    def __init__(self, primary: BaseSessionService, fallback: BaseSessionService):
        super().__init__()
        self._primary = primary
        self._fallback = fallback

    async def create_session(self, *args, **kwargs):
        try:
            return await self._primary.create_session(*args, **kwargs)
        except Exception:
            return await self._fallback.create_session(*args, **kwargs)

    async def get_session(self, *args, **kwargs):
        try:
            session = await self._primary.get_session(*args, **kwargs)
            if session:
                return session
        except Exception:
            pass
        return await self._fallback.get_session(*args, **kwargs)

    async def list_sessions(self, *args, **kwargs):
        try:
            return await self._primary.list_sessions(*args, **kwargs)
        except Exception:
            return await self._fallback.list_sessions(*args, **kwargs)

    async def delete_session(self, *args, **kwargs):
        try:
            return await self._primary.delete_session(*args, **kwargs)
        except Exception:
            return await self._fallback.delete_session(*args, **kwargs)

    async def append_event(self, session, event):
        try:
            return await self._primary.append_event(session, event)
        except Exception:
            return await self._fallback.append_event(session, event)


@functools.cache
def get_session_service():
    """Process-wide session service shared across every serving surface."""
    if uri := os.environ.get("SESSION_SERVICE_URI"):
        return create_session_service_from_options(
            base_dir=_AGENT_DIR, session_service_uri=uri
        )
    fallback_in_memory = InMemorySessionService()
    if agent_engine_id := os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_ID"):
        try:
            from google.adk.sessions.vertex_ai_session_service import VertexAiSessionService

            project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("PROJECT_ID")
            if not project:
                try:
                    import google.auth
                    _, project = google.auth.default()
                except Exception:
                    pass

            primary_vertex = VertexAiSessionService(
                project=project,
                location=os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_LOCATION")
                or os.environ.get("GOOGLE_CLOUD_REGION")
                or "us-central1",
                agent_engine_id=agent_engine_id,
            )
            return ResilientSessionService(primary=primary_vertex, fallback=fallback_in_memory)
        except Exception:
            pass

    return fallback_in_memory


@functools.cache
def get_artifact_service():
    """Process-wide artifact service: GCS when a bucket is set, else in-memory."""
    if bucket := os.environ.get("LOGS_BUCKET_NAME"):
        return GcsArtifactService(bucket_name=bucket)
    return InMemoryArtifactService()


_registry = get_service_registry()
_registry.register_session_service("shared", lambda uri, **kw: get_session_service())
_registry.register_artifact_service("shared", lambda uri, **kw: get_artifact_service())
