---
name: refund-policy
description: Use this skill to evaluate refund eligibility under company policy and execute refunds using the Order MCP Server.
metadata:
  adk_additional_tools:
    - get_order
    - process_refund
---

# Refund Policy & Execution Skill

Follow these exact company refund rules before issuing any refund:

## 1. Eligibility Rules
- **Eligible Statuses**: Orders with status `delayed` or `delivered` **ARE eligible** for a full refund.
- **Ineligible Statuses**: Orders with status `shipped` **ARE NOT eligible** for a refund yet (the customer must wait until delivery or a delay).
- **Already Refunded**: Orders where `refunded` is `true` cannot be refunded a second time.

## 2. Execution Steps
1. If you do not already have the order's status, call `get_order(order_id=<order_id>)` first.
2. Check the status against the Eligibility Rules above.
3. If eligible, call the `process_refund(order_id=<order_id>, reason=<reason>)` MCP tool.
4. Call `finish_task` with the structured `RefundOutput` (`order_id`, `refund_processed`, and `message`).
