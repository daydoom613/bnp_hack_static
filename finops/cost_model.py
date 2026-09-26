#!/usr/bin/env python3
"""Projected monthly compute cost of a Terraform plan, priced from the pricing matrix.

    terraform show -json tfplan > plan.json
    python finops/cost_model.py --plan plan.json --pricing data/pricing_matrix.csv --out cost_model.json

Writes Infracost-shaped JSON (the same shape as data/baseline_cost.json) that the
OPA budget rule in policies/budget.rego compares against budget_cap.

Decisions (docs/contracts.md):
  * Projected cost uses each ASG's max_size: the most the plan could ever run.
  * Only EC2 compute is priced; the matrix has no ALB/NAT/RDS rates. Those are
    identical in the static and dynamic stacks, so they cancel out of the
    avoided cost. Infracost runs alongside in CI for the full bill.
  * An instance type missing from the matrix goes to UnpricedResources and OPA
    blocks the plan: a plan that cannot be priced cannot be proven within budget.
"""
import argparse
import csv
import json
import math
import sys

HOURS_PER_MONTH = 730


def load_pricing(path, region):
    prices = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            if row["region"].strip() != region:
                continue
            prices[row["instance_type"].strip()] = {
                "on_demand": float(row["on_demand_price_per_hour"]),
                "reserved": float(row["reserved_price_per_hour"]),
                "spot": float(row["spot_price_per_hour"]),
            }
    if not prices:
        sys.exit(f"{path}: no prices for region {region}")
    return prices


def plan_region(plan):
    region = plan.get("variables", {}).get("aws_region", {}).get("value")
    if region:
        return region
    try:
        return plan["configuration"]["provider_config"]["aws"]["expressions"]["region"]["constant_value"]
    except KeyError:
        sys.exit("cannot work out the region from the plan; pass --region")


def first(blocks):
    """Terraform renders nested blocks as lists; return the first one or {}."""
    return blocks[0] if blocks else {}


def live_resources(plan):
    """Managed resources that still exist after the plan is applied."""
    for rc in plan.get("resource_changes", []):
        if rc.get("mode") != "managed" or rc["change"]["actions"] == ["delete"]:
            continue
        yield rc, rc["change"].get("after") or {}


def asg_candidate_types(asg, launch_templates):
    """Instance types an ASG may launch. More than one means we price the dearest."""
    lt_spec = first(first(asg.get("mixed_instances_policy")).get("launch_template"))
    overrides = [o["instance_type"] for o in lt_spec.get("override") or [] if o.get("instance_type")]
    if overrides:
        return overrides

    # Launch template ids are unknown at plan time, so match within the module:
    # by name when it is known, otherwise every template the module defines.
    wanted = first(asg.get("launch_template")).get("name") or first(lt_spec.get("launch_template_specification")).get("launch_template_name")
    named = [lt for lt in launch_templates if wanted and lt.get("name") == wanted]
    return [lt.get("instance_type") for lt in (named or launch_templates)]


def asg_split(asg, capacity):
    """(on_demand_count, spot_count) at the given capacity."""
    mip = first(asg.get("mixed_instances_policy"))
    if not mip:
        return capacity, 0
    dist = first(mip.get("instances_distribution"))
    base = dist.get("on_demand_base_capacity") or 0
    pct = dist.get("on_demand_percentage_above_base_capacity")
    pct = 100 if pct is None else pct
    base = min(base, capacity)
    # AWS rounds the On-Demand share up.
    on_demand = base + math.ceil((capacity - base) * pct / 100)
    return on_demand, capacity - on_demand


def estimate(plan, prices, region, on_demand_rate="on_demand", name="terraform-plan"):
    launch_templates = {}
    for rc, after in live_resources(plan):
        if rc["type"] == "aws_launch_template":
            launch_templates.setdefault(rc.get("module_address", ""), []).append(after)

    resources, unpriced = [], []

    def price(address, rtype, candidates, on_demand, spot):
        known = [t for t in candidates if t in prices]
        missing = [t for t in candidates if t not in prices]
        if missing or not known:
            unpriced.append({"Name": address, "InstanceType": ", ".join(str(t) for t in missing) or "unknown"})
            return
        # Several candidate types: price at the most expensive (upper bound).
        itype = max(known, key=lambda t: prices[t]["on_demand"])
        p = prices[itype]
        monthly = (on_demand * p[on_demand_rate] + spot * p["spot"]) * HOURS_PER_MONTH
        resources.append({
            "Name": address,
            "Type": rtype,
            "InstanceType": itype,
            "OnDemandCount": on_demand,
            "SpotCount": spot,
            "MonthlyCost": round(monthly, 2),
            "Pricing": {
                "OnDemand": p[on_demand_rate],
                "Spot": p["spot"],
                "Region": region,
            },
        })

    for rc, after in live_resources(plan):
        if rc["type"] == "aws_autoscaling_group":
            capacity = after.get("max_size") or 0
            on_demand, spot = asg_split(after, capacity)
            candidates = asg_candidate_types(after, launch_templates.get(rc.get("module_address", ""), []))
            price(rc["address"], rc["type"], candidates, on_demand, spot)
        elif rc["type"] == "aws_instance":
            is_spot = first(after.get("instance_market_options")).get("market_type") == "spot"
            price(rc["address"], rc["type"], [after.get("instance_type")], 0 if is_spot else 1, 1 if is_spot else 0)

    total = round(sum(r["MonthlyCost"] for r in resources), 2)
    return {
        "Version": "0.1",
        "Source": "finops/cost_model.py",
        "Region": region,
        "HoursPerMonth": HOURS_PER_MONTH,
        "OnDemandRate": on_demand_rate,
        "TotalMonthlyCost": total,
        "Projects": [{"Name": name, "TotalMonthlyCost": total, "Resources": resources}],
        "UnpricedResources": unpriced,
        "Notes": [
            "EC2 compute only, at ASG max_size, 730 h/month.",
            "ALB, NAT and RDS are the same in both stacks and cancel out of avoided cost; see Infracost for the full bill.",
        ],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True, help="terraform show -json output")
    ap.add_argument("--pricing", default="data/pricing_matrix.csv")
    ap.add_argument("--out", default="-", help="output file, - for stdout")
    ap.add_argument("--region", help="defaults to the plan's aws_region")
    ap.add_argument("--name", default="terraform-plan", help="Projects[0].Name")
    ap.add_argument("--on-demand-rate", choices=["on_demand", "reserved"], default="on_demand",
                    help="price On-Demand capacity at reserved rates to model RI coverage")
    args = ap.parse_args()

    with open(args.plan, encoding="utf-8") as f:
        plan = json.load(f)
    region = args.region or plan_region(plan)
    result = estimate(plan, load_pricing(args.pricing, region), region, args.on_demand_rate, args.name)

    text = json.dumps(result, indent=2)
    if args.out == "-":
        print(text)
    else:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")

    cap = plan.get("variables", {}).get("budget_cap", {}).get("value")
    summary = f"Projected monthly compute cost: {result['TotalMonthlyCost']:.2f}"
    if cap:
        summary += f" / budget_cap {float(cap):.2f} ({100 * result['TotalMonthlyCost'] / float(cap):.1f}%)"
    print(summary, file=sys.stderr)
    for r in result["UnpricedResources"]:
        print(f"UNPRICED: {r['Name']} ({r['InstanceType']})", file=sys.stderr)


if __name__ == "__main__":
    main()
