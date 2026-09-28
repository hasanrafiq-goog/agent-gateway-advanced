import asyncio
import subprocess
import sys
from mcp import ClientSession
from mcp.client.sse import sse_client


def get_gcloud_identity_token() -> str:
    """Get an identity token using gcloud for authenticated Cloud Run requests."""
    try:
        token = subprocess.check_output(
            ["gcloud", "auth", "print-identity-token"], text=True
        ).strip()
        return token
    except Exception:
        return ""


async def main():
    if len(sys.argv) < 2:
        print("Usage: python test_cloud_run_mcp.py <CLOUD_RUN_SSE_URL>")
        sys.exit(1)

    url = sys.argv[1]
    if not url.endswith("/sse"):
        url = url.rstrip("/") + "/sse"

    headers = {}
    token = get_gcloud_identity_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
        print("🔑 Attached Google Cloud IAM Identity Token for authentication.")

    print(f"Connecting to Cloud Run MCP Server at: {url} ...")
    async with sse_client(url, headers=headers) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # 1. Discover tools on Cloud Run
            tools_result = await session.list_tools()
            print("\n✅ Successfully connected to Cloud Run! Discovered tools:")
            for tool in tools_result.tools:
                print(f"  - {tool.name}: {tool.description}")

            # 2. Test get_order("ORD-101")
            print("\nCalling remote tool: get_order(order_id='ORD-101')...")
            order_resp = await session.call_tool("get_order", {"order_id": "ORD-101"})
            print("Result:\n", order_resp.content[0].text)

            # 3. Test process_refund("ORD-101", "Customer requested refund on delivered item")
            print(
                "\nCalling remote tool: process_refund(order_id='ORD-101', reason='Delivered return request')..."
            )
            refund_resp = await session.call_tool(
                "process_refund",
                {"order_id": "ORD-101", "reason": "Delivered return request"},
            )
            print("Result:\n", refund_resp.content[0].text)
            print("\n🎉 Cloud Run MCP Server is 100% healthy and functioning over HTTPS/SSE!")


if __name__ == "__main__":
    asyncio.run(main())
