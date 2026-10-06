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

import os
from pathlib import Path
from typing import Any, Optional

# Inject Agent Gateway root CA into Python & gRPC trust stores for egress inspection
try:
    import certifi
    ca_bundle = certifi.where()
    with open(ca_bundle, "r") as f:
        existing_certs = f.read()

    # Load CA from bundled certificate file, environment variable, or known paths
    ca_cert_file = Path(__file__).parent / "gateway_ca.crt"
    gateway_cert = ""
    if ca_cert_file.exists():
        gateway_cert = ca_cert_file.read_text().strip()
    elif os.environ.get("AGENT_GATEWAY_ROOT_CERT"):
        gateway_cert = os.environ.get("AGENT_GATEWAY_ROOT_CERT", "").strip()

    if gateway_cert and gateway_cert not in existing_certs:
        custom_bundle = "/tmp/ca-bundle-custom.crt"
        with open(custom_bundle, "w") as f:
            f.write(existing_certs + "\n" + gateway_cert + "\n")
        os.environ["SSL_CERT_FILE"] = custom_bundle
        os.environ["REQUESTS_CA_BUNDLE"] = custom_bundle
        os.environ["GRPC_DEFAULT_SSL_ROOTS_FILE_PATH"] = custom_bundle
        certifi.where = lambda: custom_bundle
except Exception:
    pass

import google.auth
import google.auth.transport.requests
from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.adk.skills import load_skill_from_dir
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import SseConnectionParams
from google.adk.tools.skill_toolset import SkillToolset
from google.genai import types
from pydantic import BaseModel, Field

MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL", "http://127.0.0.1:8085/sse")
SKILLS_DIR = Path(__file__).parent / "skills"


def get_auth_headers(context: Optional[Any] = None) -> dict[str, str]:
    """Dynamically fetches OIDC ID tokens for Cloud Run or OAuth access tokens for Google APIs."""
    from urllib.parse import urlparse
    import google.auth
    import google.auth.transport.requests

    parsed = urlparse(MCP_SERVER_URL)
    audience = f"{parsed.scheme}://{parsed.netloc}"
    auth_req = google.auth.transport.requests.Request()

    # 1. Attempt to fetch OIDC ID token for the Cloud Run audience via metadata server
    try:
        from google.oauth2 import id_token
        token = id_token.fetch_id_token(auth_req, audience)
        if token:
            return {"Authorization": f"Bearer {token}"}
    except Exception:
        pass

    # 2. Fallback: Refresh ADC / Service Account credentials
    try:
        credentials, project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        credentials.refresh(auth_req)
        token = getattr(credentials, "id_token", None) or credentials.token
        target_project = os.getenv("GOOGLE_CLOUD_PROJECT") or project or ""
        headers = {"Authorization": f"Bearer {token}"}
        if target_project:
            headers["x-goog-user-project"] = target_project
        return headers
    except Exception:
        return {}


# Shared model config preserved from scaffold
MODEL_CONFIG = Gemini(
    model="gemini-3.8-flash",
    retry_options=types.HttpRetryOptions(attempts=3),
)


class OrderLookupOutput(BaseModel):
    order_id: str = Field(description="The order ID queried.")
    found: bool = Field(description="Whether the order was found.")
    status: str = Field(description="Current shipping status of the order.")
    card_number: Optional[str] = Field(default=None, description="The payment card number associated with the order.")
    summary: str = Field(description="Human-readable summary of order details including item, price, customer, card_number, and status.")


class RefundOutput(BaseModel):
    order_id: str = Field(description="The order ID for the refund request.")
    refund_processed: bool = Field(description="True if the refund was executed, False if rejected.")
    message: str = Field(description="Explanation or confirmation message from the refund action.")


# Sub-Agent 1: Skill-Based Order Tracker (ADK 2.0 SkillToolset + McpToolset)
order_tracker = Agent(
    name="order_tracker",
    model=MODEL_CONFIG,
    mode="task",
    output_schema=OrderLookupOutput,
    description="Looks up order details, price, customer, card number, and shipping status by order_id using the order-tracking skill.",
    instruction=(
        "You are the Order Tracker specialist. "
        "Load the `order-tracking` skill first using `load_skill` to unlock the MCP order tool and instructions, "
        "then look up the order and call `finish_task` ensuring card_number is included."
    ),
    tools=[
        SkillToolset(
            skills=[load_skill_from_dir(SKILLS_DIR / "order-tracking")],
            additional_tools=[
                McpToolset(
                    connection_params=SseConnectionParams(
                        url=MCP_SERVER_URL,
                    ),
                    header_provider=get_auth_headers,
                    tool_filter=["get_order"],
                )
            ],
        )
    ],
)

# Sub-Agent 2: Skill-Based Refund Specialist (ADK 2.0 SkillToolset + McpToolset)
refund_specialist = Agent(
    name="refund_specialist",
    model=MODEL_CONFIG,
    mode="task",
    output_schema=RefundOutput,
    description="Evaluates refund eligibility and processes refunds using the refund-policy skill.",
    instruction=(
        "You are the Refund Specialist. "
        "Load the `refund-policy` skill first using `load_skill` to read company refund rules and unlock the MCP refund tools, "
        "then process or reject the refund and call `finish_task`."
    ),
    tools=[
        SkillToolset(
            skills=[load_skill_from_dir(SKILLS_DIR / "refund-policy")],
            additional_tools=[
                McpToolset(
                    connection_params=SseConnectionParams(
                        url=MCP_SERVER_URL,
                    ),
                    header_provider=get_auth_headers,
                    tool_filter=["get_order", "process_refund"],
                )
            ],
        )
    ],
)

# Root Coordinator Agent
root_agent = Agent(
    name="root_agent",
    model=MODEL_CONFIG,
    instruction=(
        "You are the Customer Support Coordinator for an e-commerce store. "
        "Delegate order status lookups to `order_tracker` and refund requests to `refund_specialist`. "
        "Always check the order status first if you don't know it before requesting a refund. "
        "When reporting order details or status, always include the payment card number along with the item and status. "
        "Provide a clear, friendly response summarizing what the specialist agents found or did."
    ),
    sub_agents=[order_tracker, refund_specialist],
)

app = App(
    root_agent=root_agent,
    name="app",
)
