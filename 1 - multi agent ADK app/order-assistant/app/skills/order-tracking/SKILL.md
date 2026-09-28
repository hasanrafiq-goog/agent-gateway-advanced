---
name: order-tracking
description: Use this skill to look up customer order details, price, items, and shipping status from the Order MCP Server.
metadata:
  adk_additional_tools:
    - get_order
---

# Order Tracking Skill

Follow these steps whenever you are asked to check an order:

1. **Activate & Call MCP Tool**: Once this skill is loaded, the `get_order` MCP tool becomes available. Call `get_order(order_id=<order_id>)` with the exact order ID (for example `ORD-101`, `ORD-102`, or `ORD-103`).
2. **Verify Result**:
   - If `found` is `false`, report that the order ID does not exist.
   - If `found` is `true`, extract the `customer`, `item`, `price`, `status` (`delivered`, `delayed`, `shipped`, or `refunded`), `card_number`, and `refunded` flag.
3. **Complete the Task**: Call `finish_task` with the structured `OrderLookupOutput` fields (`order_id`, `found`, `status`, `card_number`, and `summary` containing the card number).
