# ruff: noqa
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

import base64
import contextlib
import inspect
import json
import os
from collections.abc import AsyncIterator
from typing import Any, Optional

import google.auth
from a2a.server.tasks import InMemoryTaskStore
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, status
from google.adk.cli.fast_api import get_fast_api_app
from google.adk.runners import Runner
from google.cloud import logging as google_cloud_logging
from pydantic import BaseModel

from app.app_utils import services
from app.app_utils.a2a import attach_a2a_routes
from app.app_utils.reasoning_engine_adapter import (
    attach_reasoning_engine_routes,
)
from app.app_utils.telemetry import (
    setup_agent_engine_telemetry,
    setup_telemetry,
)
from app.app_utils.typing import Feedback

# Opt out of CAA token sharing enforcement for internal Google API calls
os.environ["GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES"] = "false"
if not os.environ.get("GOOGLE_CLOUD_PROJECT"):
    try:
        _, detected_project = google.auth.default()
        if detected_project:
            os.environ["GOOGLE_CLOUD_PROJECT"] = detected_project
    except Exception:
        pass

load_dotenv()
setup_telemetry()
# Must run before get_fast_api_app to set the tracer provider resource.
setup_agent_engine_telemetry()
_, project_id = google.auth.default()
logging_client = google_cloud_logging.Client()
logger = logging_client.logger(__name__)
allow_origins = (
    os.getenv("ALLOW_ORIGINS", "").split(",") if os.getenv("ALLOW_ORIGINS") else None
)

AGENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # Runner for the A2A path, sharing the same session/artifact services as the
    # adk_api and reasoning_engine paths (see services.py). Imported here so the
    # agent is built after env/telemetry setup.
    from app.agent import app as adk_app
    from app.agent import root_agent

    runner = Runner(
        app=adk_app,
        session_service=services.get_session_service(),
        artifact_service=services.get_artifact_service(),
        auto_create_session=True,
    )
    # Shared by the A2A path and the reasoning_engine adapter routes.
    app.state.runner = runner
    app.state.agent_app_name = adk_app.name
    await attach_a2a_routes(
        app,
        agent=root_agent,
        runner=runner,
        task_store=InMemoryTaskStore(),
        rpc_path=f"/a2a/{adk_app.name}",
    )
    yield


app: FastAPI = get_fast_api_app(
    agents_dir=AGENT_DIR,
    web=True,
    artifact_service_uri=services.ARTIFACT_SERVICE_URI,
    allow_origins=allow_origins,
    session_service_uri=services.SESSION_SERVICE_URI,
    otel_to_cloud=False,
    lifespan=lifespan,
)
app.title = "order-assistant"
app.description = "API for interacting with the Agent order-assistant"


# Proxy routes so the Vertex AI Console Playground (reasoning_engine SDK) can
# talk to this agent alongside the native adk_api routes.
attach_reasoning_engine_routes(app)


@app.post("/feedback")
def collect_feedback(feedback: Feedback) -> dict[str, str]:
    """Collect and log feedback.

    Args:
        feedback: The feedback data to log

    Returns:
        Success message
    """
    logger.log_struct(feedback.model_dump(), severity="INFO")
    return {"status": "success"}


class SessionInitRequest(BaseModel):
    user_id: Optional[str] = None
    token: Optional[str] = None
    state: Optional[dict[str, Any]] = None


def _extract_jwt_claims(token: str) -> dict[str, Any]:
    """Parse JWT claims payload safely from base64."""
    try:
        if token.lower().startswith("bearer "):
            token = token[7:].strip()
        parts = token.split(".")
        if len(parts) >= 2:
            payload_b64 = parts[1]
            payload_b64 += "=" * (-len(payload_b64) % 4)
            decoded_bytes = base64.urlsafe_b64decode(payload_b64)
            return json.loads(decoded_bytes.decode("utf-8"))
    except Exception as e:
        logger.log_text(f"Failed to decode JWT claims: {e}", severity="WARNING")
    return {}


@app.post("/session/init")
@app.post("/api/session/init")
async def init_session(
    request: Request,
    body: Optional[SessionInitRequest] = None,
) -> dict[str, Any]:
    """Initialize an ADK conversation session with end-user JWT and scopes in state."""
    # 1. Extract token from header or body
    token = (
        request.headers.get("X-User-Token")
        or request.headers.get("X-Forwarded-Authorization")
        or (body.token if body else None)
    )
    if not token and "Authorization" in request.headers:
        auth_hdr = request.headers["Authorization"]
        if auth_hdr.startswith("Bearer ") and not auth_hdr.startswith("Bearer ya29."):
            token = auth_hdr[7:].strip()

    if not token:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Missing JWT token. Provide via 'X-User-Token' header or JSON body.",
        )

    claims = _extract_jwt_claims(token)
    user_id = (body.user_id if body and body.user_id else None) or claims.get("sub") or claims.get("user_id") or "user1"
    raw_scopes = claims.get("scopes") or claims.get("scope") or ["orders:read"]
    scopes = raw_scopes.split() if isinstance(raw_scopes, str) else list(raw_scopes)

    initial_state = {
        "user_jwt": token,
        "user_id": user_id,
        "user_email": claims.get("email", ""),
        "user_scopes": scopes,
        "user_claims": claims,
    }
    if body and body.state:
        initial_state.update(body.state)

    session_service = services.get_session_service()
    from app.agent import app as adk_app
    app_name = getattr(app.state, "agent_app_name", adk_app.name)

    res = session_service.create_session(
        app_name=app_name,
        user_id=user_id,
        state=initial_state,
    )
    session = await res if inspect.iscoroutine(res) else res

    logger.log_struct(
        {
            "event": "session_init",
            "session_id": session.id,
            "user_id": user_id,
            "scopes": scopes,
        },
        severity="INFO",
    )

    return {
        "status": "success",
        "session_id": session.id,
        "user_id": user_id,
        "scopes": scopes,
        "claims": claims,
    }


@app.get("/session/{session_id}")
@app.get("/api/session/{session_id}")
async def get_session_info(
    session_id: str,
    user_id: str = "user1",
) -> dict[str, Any]:
    """Retrieve session state for validation and debugging."""
    session_service = services.get_session_service()
    from app.agent import app as adk_app
    app_name = getattr(app.state, "agent_app_name", adk_app.name)

    res = session_service.get_session(
        app_name=app_name,
        user_id=user_id,
        session_id=session_id,
    )
    session = await res if inspect.iscoroutine(res) else res
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return {
        "session_id": session.id,
        "user_id": session.user_id,
        "state": session.state,
    }


# Main execution
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
