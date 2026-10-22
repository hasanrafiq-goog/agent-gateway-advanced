import os
from mcp.server.fastmcp import FastMCP

PORT = int(os.environ.get("PORT", 8085))

mcp = FastMCP(
    "Order & Refund MCP Server",
    host="0.0.0.0",
    port=PORT,
    stateless_http=True,
)

# Immutable mock database of orders (stateless across requests)
INITIAL_ORDERS = {
    "ORD-101": {
        "order_id": "ORD-101",
        "customer": "Alice",
        "item": "Wireless Headphones",
        "price": 120.00,
        "status": "delivered",
        "card_number": "4532-0123-4567-8902",
        "refunded": False,
    },
    "ORD-102": {
        "order_id": "ORD-102",
        "customer": "Bob",
        "item": "Mechanical Keyboard",
        "price": 85.00,
        "status": "delayed",
        "card_number": "4532-1234-5678-9014",
        "refunded": False,
    },
    "ORD-103": {
        "order_id": "ORD-103",
        "customer": "Charlie",
        "item": "USB-C Monitor",
        "price": 310.00,
        "status": "shipped",
        "card_number": "4532-9876-5432-1097",
        "refunded": False,
    },
}


@mcp.tool()
def get_order(order_id: str) -> dict:
    """Look up order details and shipping status by order_id (e.g., ORD-101, ORD-102, ORD-103)."""
    order = INITIAL_ORDERS.get(order_id.upper())
    if not order:
        return {"found": False, "error": f"Order '{order_id}' not found."}
    return {"found": True, "order": dict(order)}


@mcp.tool()
def process_refund(order_id: str, reason: str) -> dict:
    """Process a refund for an order given its order_id and the reason for the refund."""
    order = INITIAL_ORDERS.get(order_id.upper())
    if not order:
        return {"success": False, "error": f"Order '{order_id}' not found."}

    # Generate refund response without mutating the static in-memory database
    refund_record = dict(order)
    refund_record["refunded"] = True
    refund_record["status"] = "refunded"
    refund_record["refund_reason"] = reason

    return {
        "success": True,
        "message": f"Refund of ${order['price']:.2f} processed for {order['order_id']} ({order['item']}).",
        "order": refund_record,
    }


if __name__ == "__main__":
    import uvicorn
    from starlette.routing import Mount

    # Build the primary Streamable HTTP app (used by AgentRegistry.get_mcp_toolset)
    # and mount SSE routes alongside root Streamable HTTP for backward compatibility.
    app = mcp.streamable_http_app()
    sse_app = mcp.sse_app()
    for route in sse_app.routes:
        app.routes.append(route)
    for route in list(app.routes):
        if getattr(route, "path", None) == "/mcp":
            app.routes.append(Mount("/", app=route.app))
            break

    print(f"Starting MCP Server on http://0.0.0.0:{PORT} (Streamable HTTP & SSE) ...")
    uvicorn.run(app, host="0.0.0.0", port=PORT)
