from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
from datetime import datetime, timedelta
from decimal import Decimal
import logging

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'postgresql://user:pass@localhost/stockflow'
db = SQLAlchemy(app)
logger = logging.getLogger(__name__)

# ============================================================
# ASSUMPTIONS (due to incomplete requirements)
# ============================================================
# 1. "Recent sales activity" = any sale in the last 30 days
# 2. Sales velocity = total units sold / 30 days (daily average)
# 3. Days until stockout = current_stock / daily_sales_velocity
# 4. Threshold source priority: product-level > category-level > default (10)
# 5. Preferred supplier determined by is_preferred flag, then lowest cost
# 6. Authentication/authorization handled by middleware (not shown)
# ============================================================


@app.route('/api/companies/<int:company_id>/alerts/low-stock', methods=['GET'])
def get_low_stock_alerts(company_id: int):
    """
    Returns low-stock alerts for all products below their threshold
    that have had recent sales activity.
    
    Business Rules Implemented:
    - Low stock threshold varies by product (product.low_stock_threshold 
      falls back to category default if not set)
    - Only includes products with sales in the last 30 days
    - Handles multiple warehouses per company
    - Includes preferred supplier information for reordering
    """
    
    # ----------------------------------------------------------
    # STEP 1: Validate company exists
    # ----------------------------------------------------------
    company = db.session.execute(
        text("SELECT id FROM companies WHERE id = :id AND is_active = TRUE"),
        {"id": company_id}
    ).fetchone()
    
    if not company:
        return jsonify({"error": "Company not found"}), 404
    
    # ----------------------------------------------------------
    # STEP 2: Define "recent activity" window (last 30 days)
    # ----------------------------------------------------------
    lookback_days = 30
    lookback_date = datetime.utcnow().date() - timedelta(days=lookback_days)
    
    # ----------------------------------------------------------
    # STEP 3: Query for low-stock products with recent sales
    # ----------------------------------------------------------
    # This query:
    # - Calculates effective threshold per product
    # - Computes sales velocity from last 30 days
    # - Filters to products below threshold with recent activity
    # - Joins preferred supplier info
    
    query = text("""
        WITH sales_velocity AS (
            -- Calculate average daily sales per product-warehouse
            SELECT 
                product_id,
                warehouse_id,
                SUM(quantity_sold)::DECIMAL / :lookback_days AS avg_daily_sales
            FROM daily_sales_summary
            WHERE sale_date >= :lookback_date
            GROUP BY product_id, warehouse_id
            HAVING SUM(quantity_sold) > 0  -- Must have recent sales
        ),
        effective_thresholds AS (
            -- Get threshold: product-level OR category default OR 10
            SELECT 
                p.id AS product_id,
                p.name AS product_name,
                p.sku,
                COALESCE(p.low_stock_threshold, pc.low_stock_threshold_default, 10) AS threshold
            FROM products p
            LEFT JOIN product_categories pc ON p.category_id = pc.id
            WHERE p.company_id = :company_id AND p.is_active = TRUE
        ),
        preferred_suppliers AS (
            -- Get one supplier per product (prefer is_preferred, then lowest cost)
            SELECT DISTINCT ON (ps.product_id)
                ps.product_id,
                s.id AS supplier_id,
                s.name AS supplier_name,
                s.contact_email
            FROM product_suppliers ps
            JOIN suppliers s ON ps.supplier_id = s.id AND s.is_active = TRUE
            ORDER BY ps.product_id, ps.is_preferred DESC, ps.unit_cost ASC
        )
        SELECT 
            et.product_id,
            et.product_name,
            et.sku,
            w.id AS warehouse_id,
            w.name AS warehouse_name,
            i.quantity AS current_stock,
            et.threshold,
            -- Calculate days until stockout (NULL if can't calculate)
            CASE 
                WHEN sv.avg_daily_sales > 0 
                THEN FLOOR(i.quantity / sv.avg_daily_sales)::INTEGER
                ELSE NULL
            END AS days_until_stockout,
            ps.supplier_id,
            ps.supplier_name,
            ps.contact_email
        FROM inventory i
        JOIN effective_thresholds et ON i.product_id = et.product_id
        JOIN warehouses w ON i.warehouse_id = w.id AND w.company_id = :company_id
        JOIN sales_velocity sv ON i.product_id = sv.product_id 
            AND i.warehouse_id = sv.warehouse_id
        LEFT JOIN preferred_suppliers ps ON i.product_id = ps.product_id
        WHERE i.quantity < et.threshold  -- Below threshold = low stock
        ORDER BY days_until_stockout ASC NULLS LAST
    """)
    
    try:
        results = db.session.execute(query, {
            "company_id": company_id,
            "lookback_date": lookback_date,
            "lookback_days": lookback_days
        }).fetchall()
    except Exception as e:
        logger.error(f"Database error: {e}")
        return jsonify({"error": "Failed to fetch alerts"}), 500
    
    # ----------------------------------------------------------
    # STEP 4: Build response matching expected format
    # ----------------------------------------------------------
    alerts = []
    for row in results:
        alert = {
            "product_id": row.product_id,
            "product_name": row.product_name,
            "sku": row.sku,
            "warehouse_id": row.warehouse_id,
            "warehouse_name": row.warehouse_name,
            "current_stock": row.current_stock,
            "threshold": row.threshold,
            "days_until_stockout": row.days_until_stockout
        }
        
        # Include supplier if available
        if row.supplier_id:
            alert["supplier"] = {
                "id": row.supplier_id,
                "name": row.supplier_name,
                "contact_email": row.contact_email
            }
        else:
            alert["supplier"] = None
        
        alerts.append(alert)
    
    return jsonify({
        "alerts": alerts,
        "total_alerts": len(alerts)
    }), 200


if __name__ == '__main__':
    app.run(debug=True)