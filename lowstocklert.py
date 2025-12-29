 

 

from flask import Flask, jsonify, request 

from sqlalchemy import func, and_, or_, text 

from sqlalchemy.orm import joinedload 

from datetime import datetime, timedelta 

from decimal import Decimal 

import logging 

 

app = Flask(__name__) 

logger = logging.getLogger(__name__) 

 

 

# ============================================ 

# ASSUMPTIONS DOCUMENTED 

# ============================================ 

""" 

BUSINESS LOGIC ASSUMPTIONS: 

1. "Recent sales activity" = sales in last 30 days 

2. "Low stock" = current_stock < threshold for that product 

3. Days until stockout = current_stock / avg_daily_sales (if sales > 0) 

4. Only alert for active (non-deleted) products 

5. Only check warehouses that are active 

6. Use preferred supplier if available, otherwise first supplier 

7. Consider only quantity_available (not reserved or damaged) 

 

DATABASE ASSUMPTIONS: 

1. Using the schema from Part 2 (organizations, products, inventory, etc.) 

2. We have a sales_orders table to track recent sales: 

   - sales_orders: id, organization_id, order_date, status 

   - sales_order_items: order_id, product_id, quantity, warehouse_id 

3. Company = Organization (using organization_id) 

 

PERFORMANCE ASSUMPTIONS: 

1. This is a read-heavy endpoint (no writes) 

2. Results should be cacheable (Redis) for 5-10 minutes 

3. Expected to return < 1000 alerts per organization 

4. Query should complete in < 2 seconds 

""" 

 

 

# ============================================ 

# HELPER FUNCTIONS 

# ============================================ 

 

def calculate_days_until_stockout(current_stock, avg_daily_sales): 

    """ 

    Calculate estimated days until stock runs out 

     

    Args: 

        current_stock: Current available inventory 

        avg_daily_sales: Average daily sales over recent period 

         

    Returns: 

        int: Days until stockout, or None if can't calculate 

    """ 

    if avg_daily_sales is None or avg_daily_sales <= 0: 

        return None  # Can't predict if no sales history 

     

    if current_stock <= 0: 

        return 0  # Already out of stock 

     

    days = current_stock / avg_daily_sales 

    return int(days) 

 

 

def get_preferred_supplier(product_id): 

    """ 

    Get the preferred supplier for a product, or first available supplier 

     

    Args: 

        product_id: Product ID 

         

    Returns: 

        dict: Supplier information or None 

    """ 

    # Try to get preferred supplier first 

    supplier_relation = ProductSupplier.query.filter_by( 

        product_id=product_id, 

        is_preferred=True 

    ).join(Supplier).filter( 

        Supplier.is_active == True 

    ).first() 

     

    # If no preferred supplier, get any active supplier 

    if not supplier_relation: 

        supplier_relation = ProductSupplier.query.filter_by( 

            product_id=product_id 

        ).join(Supplier).filter( 

            Supplier.is_active == True 

        ).first() 

     

    if not supplier_relation: 

        return None 

     

    supplier = supplier_relation.supplier 

    return { 

        "id": supplier.id, 

        "name": supplier.name, 

        "contact_email": supplier.contact_email, 

        "contact_phone": supplier.contact_phone, 

        "lead_time_days": supplier_relation.lead_time_days, 

        "minimum_order_quantity": supplier_relation.minimum_order_quantity, 

        "cost_price": float(supplier_relation.cost_price) if supplier_relation.cost_price else None 

    } 

 

 

def get_recent_sales_data(organization_id, days=30): 

    """ 

    Get average daily sales per product per warehouse for recent period 

     

    Args: 

        organization_id: Organization ID 

        days: Number of days to look back (default 30) 

         

    Returns: 

        dict: {(product_id, warehouse_id): avg_daily_sales} 

    """ 

    cutoff_date = datetime.utcnow() - timedelta(days=days) 

     

    # Query to calculate average daily sales 

    # SUM(quantity) / days for each product-warehouse combination 

    query = db.session.query( 

        SalesOrderItem.product_id, 

        SalesOrderItem.warehouse_id, 

        func.sum(SalesOrderItem.quantity).label('total_quantity') 

    ).join( 

        SalesOrder, 

        SalesOrderItem.order_id == SalesOrder.id 

    ).filter( 

        SalesOrder.organization_id == organization_id, 

        SalesOrder.order_date >= cutoff_date, 

        SalesOrder.status.in_(['completed', 'shipped', 'delivered'])  # Only confirmed sales 

    ).group_by( 

        SalesOrderItem.product_id, 

        SalesOrderItem.warehouse_id 

    ).all() 

     

    # Calculate average daily sales 

    sales_data = {} 

    for row in query: 

        product_id = row.product_id 

        warehouse_id = row.warehouse_id 

        total_quantity = row.total_quantity 

        avg_daily = total_quantity / days 

        sales_data[(product_id, warehouse_id)] = avg_daily 

     

    return sales_data 

 

 

# ============================================ 

# MAIN ENDPOINT 

# ============================================ 

 

@app.route('/api/companies/<int:company_id>/alerts/low-stock', methods=['GET']) 

def get_low_stock_alerts(company_id): 

    """ 

    Get low stock alerts for a company across all warehouses 

     

    Query Parameters: 

        - warehouse_id (optional): Filter by specific warehouse 

        - threshold_multiplier (optional): Adjust sensitivity (default 1.0) 

        - include_no_sales (optional): Include products with no recent sales (default false) 

        - limit (optional): Maximum number of alerts to return (default 100) 

     

    Returns: 

        JSON response with low stock alerts and supplier information 

    """ 

    try: 

        # ============================================ 

        # 1. AUTHENTICATION & AUTHORIZATION 

        # ============================================ 

        # In production, verify JWT token and check user permissions 

        current_user = get_current_user()  # Mock function 

        if not current_user: 

            return jsonify({"error": "Unauthorized"}), 401 

         

        # Verify user has access to this organization 

        if not current_user.has_access_to_organization(company_id): 

            return jsonify({"error": "Access denied"}), 403 

         

        # ============================================ 

        # 2. VALIDATE INPUT & PARSE PARAMETERS 

        # ============================================ 

        warehouse_id = request.args.get('warehouse_id', type=int) 

        threshold_multiplier = request.args.get('threshold_multiplier', default=1.0, type=float) 

        include_no_sales = request.args.get('include_no_sales', default='false').lower() == 'true' 

        limit = request.args.get('limit', default=100, type=int) 

         

        # Validate parameters 

        if threshold_multiplier <= 0: 

            return jsonify({"error": "threshold_multiplier must be positive"}), 400 

         

        if limit > 1000: 

            return jsonify({"error": "limit cannot exceed 1000"}), 400 

         

        # Verify organization exists and is active 

        organization = Organization.query.get(company_id) 

        if not organization or not organization.is_active: 

            return jsonify({"error": "Organization not found"}), 404 

         

        # ============================================ 

        # 3. CHECK CACHE (Redis) 

        # ============================================ 

        cache_key = f"low_stock_alerts:{company_id}:{warehouse_id}:{threshold_multiplier}:{include_no_sales}" 

         

        # Try to get from cache 

        cached_result = redis_client.get(cache_key) 

        if cached_result: 

            logger.info(f"Cache hit for low stock alerts: {cache_key}") 

            return jsonify(json.loads(cached_result)), 200 

         

        # ============================================ 

        # 4. GET RECENT SALES DATA 

        # ============================================ 

        logger.info (f"Calculating recent sales for organization {company_id}") 

        sales_data = get_recent_sales_data(company_id, days=30) 

         

        # ============================================ 

        # 5. BUILD MAIN QUERY FOR LOW STOCK PRODUCTS 

        # ============================================ 

         

        # Base query: Join inventory with products and warehouses 

        query = db.session.query( 

            Product.id.label('product_id'), 

            Product.name.label('product_name'), 

            Product.sku, 

            Product.low_stock_threshold, 

            Product.category, 

            Inventory.warehouse_id, 

            Warehouse.name.label('warehouse_name'), 

            Inventory.quantity_available.label('current_stock'), 

            Inventory.last_counted_at 

        ).select_from( 

            Inventory 

        ).join( 

            Product, 

            Inventory.product_id == Product.id 

        ).join( 

            Warehouse, 

            Inventory.warehouse_id == Warehouse.id 

        ).filter( 

            # Organization filter 

            Product.organization_id == company_id, 

             

            # Only active products and warehouses 

            Product.is_deleted == False, 

            Warehouse.is_active == True, 

             

            # Low stock condition: current_stock < (threshold * multiplier) 

            Inventory.quantity_available < (Product.low_stock_threshold * threshold_multiplier) 

        ) 

         

        # Optional: Filter by specific warehouse 

        if warehouse_id: 

            query = query.filter(Inventory.warehouse_id == warehouse_id) 

         

        # Execute query 

        low_stock_items = query.all() 

         

        logger.info(f"Found {len(low_stock_items)} potential low stock items") 

         

        # ============================================ 

        # 6. FILTER BY RECENT SALES ACTIVITY 

        # ============================================ 

        alerts = [] 

         

        for item in low_stock_items: 

            product_id = item.product_id 

            warehouse_id = item.warehouse_id 

             

            # Get sales data for this product-warehouse combination 

            avg_daily_sales = sales_data.get((product_id, warehouse_id), 0) 

             

            # Skip products with no recent sales (unless explicitly requested) 

            if not include_no_sales and avg_daily_sales == 0: 

                logger.debug(f"Skipping product {product_id} - no recent sales") 

                continue 

             

            # ============================================ 

            # 7. CALCULATE DAYS UNTIL STOCKOUT 

            # ============================================ 

            days_until_stockout = calculate_days_until_stockout( 

                item.current_stock, 

                avg_daily_sales 

            ) 

             

            # ============================================ 

            # 8. GET SUPPLIER INFORMATION 

            # ============================================ 

            supplier_info = get_preferred_supplier(product_id) 

             

            # ============================================ 

            # 9. BUILD ALERT OBJECT 

            # ============================================ 

            alert = { 

                "product_id": item.product_id, 

                "product_name": item.product_name, 

                "sku": item.sku, 

                "category": item.category, 

                "warehouse_id": item.warehouse_id, 

                "warehouse_name": item.warehouse_name, 

                "current_stock": item.current_stock, 

                "threshold": item.low_stock_threshold, 

                "days_until_stockout": days_until_stockout, 

                "avg_daily_sales": round(avg_daily_sales, 2) if avg_daily_sales > 0 else None, 

                "last_counted_at": item.last_counted_at.isoformat() if item.last_counted_at else None, 

                "supplier": supplier_info, 

                 

                # Additional useful fields 

                "urgency": calculate_urgency(days_until_stockout, item.current_stock), 

                "recommended_reorder_quantity": calculate_reorder_quantity( 

                    item.low_stock_threshold, 

                    item.current_stock, 

                    supplier_info 

                ) 

            } 

             

            alerts.append(alert) 

         

        # ============================================ 

        # 10. SORT BY URGENCY 

        # ============================================ 

        # Most urgent first: stockout soonest, then lowest stock 

        alerts.sort(key=lambda x: ( 

            x['days_until_stockout'] if x['days_until_stockout'] is not None else 999, 

            x['current_stock'] 

        )) 

         

        # Apply limit 

        alerts = alerts[:limit] 

         

        # ============================================ 

        # 11. BUILD RESPONSE 

        # ============================================ 

        response = { 

            "alerts": alerts, 

            "total_alerts": len(alerts), 

            "generated_at": datetime.utcnow().isoformat(), 

            "parameters": { 

                "organization_id": company_id, 

                "warehouse_id": warehouse_id, 

                "threshold_multiplier": threshold_multiplier, 

                "include_no_sales": include_no_sales, 

                "sales_period_days": 30 

            } 

        } 

         

        # ============================================ 

        # 12. CACHE RESULT 

        # ============================================ 

        redis_client.setex( 

            cache_key, 

            300,  # Cache for 5 minutes 

            json.dumps(response) 

        ) 

         

        # ============================================ 

        # 13. LOG & RETURN 

        # ============================================ 

        logger.info(f"Returning {len(alerts)} low stock alerts for org {company_id}") 

         

        return jsonify(response), 200 

         

    except Exception as e: 

        # ============================================ 

        # ERROR HANDLING 

        # ============================================ 

        logger.error(f"Error generating low stock alerts: {str(e)}", exc_info=True) 

         

        # Don't expose internal errors to client 

        return jsonify({ 

            "error": "An error occurred while generating alerts", 

            "message": "Please try again or contact support", 

            "request_id": generate_request_id()  # For debugging 

        }), 500 

 

 

# ============================================ 

# HELPER FUNCTIONS (continued) 

# ============================================ 

 

def calculate_urgency(days_until_stockout, current_stock): 

    """ 

    Calculate urgency level for the alert 

    Returns: 

        str: "critical", "high", "medium", "low" 

    """ 

    if current_stock <= 0: 

        return "critical" 

     

    if days_until_stockout is None: 

        return "low"  # No sales data, less urgent 

     

    if days_until_stockout <= 3: 

        return "critical" 

    elif days_until_stockout <= 7: 

        return "high" 

    elif days_until_stockout <= 14: 

        return "medium" 

    else: 

        return "low" 

 

 

def calculate_reorder_quantity(threshold, current_stock, supplier_info): 

    """ 

    Suggest reorder quantity based on threshold and supplier constraints 

    Args: 

        threshold: Low stock threshold 

        current_stock: Current available stock 

        supplier_info: Supplier information including MOQ 

    Returns: 

        int: Recommended reorder quantity 

    """ 

    # Base calculation: Bring stock back to 2x threshold (safety buffer) 

    target_stock = threshold * 2 

    needed = target_stock - current_stock 

     

    # Apply supplier minimum order quantity if available 

    if supplier_info and supplier_info.get('minimum_order_quantity'): 

        moq = supplier_info['minimum_order_quantity'] 

        if needed < moq: 

            needed = moq 

     

    # Round up to nearest 10 for convenience (optional) 

    needed = max(10, ((needed + 9) // 10) * 10) 

     

    return needed 

 

 

def generate_request_id(): 

    """Generate unique request ID for debugging""" 

    import uuid 

    return str(uuid.uuid4()) 
