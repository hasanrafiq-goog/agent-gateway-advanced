import asyncio
import os
from mcp import ClientSession
from mcp.client.sse import sse_client


async def main():
    port = os.environ.get("PORT", "8085")
    url = f"http://127.0.0.1:{port}/sse"
    print(f"Connecting to MCP Server at {url} ...")
    async with sse_client(url) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # 1. List tools exposed by the MCP server
            tools_result = await session.list_tools()
            print("\nDiscovered MCP Tools:")
            for tool in tools_result.tools:
                print(f" - {tool.name}: {tool.description}")

            # 2. Call get_order("ORD-102")
            print("\nCalling tool: get_order(order_id='ORD-102')...")
            order_resp = await session.call_tool("get_order", {"order_id": "ORD-102"})
            print("Result:", order_resp.content[0].text)

            # 3. Call process_refund("ORD-102", "Order delayed")
            print("\nCalling tool: process_refund(order_id='ORD-102', reason='Order delayed')...")
            refund_resp = await session.call_tool(
                "process_refund", {"order_id": "ORD-102", "reason": "Order delayed"}
            )
            print("Result:", refund_resp.content[0].text)


if __name__ == "__main__":
    asyncio.run(main())
