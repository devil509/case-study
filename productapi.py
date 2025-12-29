from flask import request, jsonify
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from decimal import Decimal, InvalidOperation
from functools import wraps


# Assuming authentication decorator exists
def require_auth(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        # Authentication logic here
        user = get_current_user()
        if not user:
            return jsonify({"error": "Unauthorized"}), 401
        return f(user, *args, **kwargs)

    return decorated_function


@app.route('/api/products', methods=['POST'])
@require_auth
def create_product(current_user):
    """
    Create a new product with initial inventory.

    Required fields: name, sku, price, warehouse_id, initial_quantity
    Returns: 201 on success, 400 on validation error, 409 on conflict
    """

    try:
        data = request.get_json()

        # Validate required fields
        required_fields = ['name', 'sku', 'price', 'warehouse_id', 'initial_quantity']
        missing_fields = [field for field in required_fields if field not in data]

        if missing_fields:
            return jsonify({
                "error": "Missing required fields",
                "missing_fields": missing_fields
            }), 400

        # Validate data types and business rules
        try:
            price = Decimal(str(data['price']))
            if price < 0:
                return jsonify({"error": "Price cannot be negative"}), 400
        except (InvalidOperation, ValueError):
            return jsonify({"error": "Invalid price format"}), 400

        try:
            initial_quantity = int(data['initial_quantity'])
            if initial_quantity < 0:
                return jsonify({"error": "Initial quantity cannot be negative"}), 400
        except (ValueError, TypeError):
            return jsonify({"error": "Invalid quantity format"}), 400

        # Validate warehouse exists and user has access
        warehouse = Warehouse.query.get(data['warehouse_id'])
        if not warehouse:
            return jsonify({"error": "Warehouse not found"}), 404

        if not current_user.has_access_to_warehouse(warehouse.id):
            return jsonify({"error": "Access denied to this warehouse"}), 403

        # Check SKU uniqueness (platform-wide)
        existing_product = Product.query.filter_by(sku=data['sku']).first()
        if existing_product:
            return jsonify({
                "error": "SKU already exists",
                "existing_product_id": existing_product.id
            }), 409

        # Begin atomic transaction
        try:
            # Create product
            product = Product(
                name=data['name'].strip(),
                sku=data['sku'].strip().upper(),  # Normalize SKU
                price=price,
                created_by=current_user.id,
                created_at=datetime.utcnow()
            )

            db.session.add(product)
            db.session.flush()  # Get product.id without committing

            # Check if inventory already exists for this warehouse
            existing_inventory = Inventory.query.filter_by(
                product_id=product.id,
                warehouse_id=data['warehouse_id']
            ).first()

            if existing_inventory:
                # Update existing inventory
                existing_inventory.quantity += initial_quantity
                existing_inventory.updated_at = datetime.utcnow()
                existing_inventory.updated_by = current_user.id
            else:
                # Create new inventory record
                inventory = Inventory(
                    product_id=product.id,
                    warehouse_id=data['warehouse_id'],
                    quantity=initial_quantity,
                    created_by=current_user.id,
                    created_at=datetime.utcnow()
                )
                db.session.add(inventory)

            # Commit everything together
            db.session.commit()

            return jsonify({
                "message": "Product created successfully",
                "product": {
                    "id": product.id,
                    "name": product.name,
                    "sku": product.sku,
                    "price": str(product.price),
                    "warehouse_id": data['warehouse_id'],
                    "initial_quantity": initial_quantity
                }
            }), 201

        except IntegrityError as e:
            db.session.rollback()
            # Handle database constraint violations
            return jsonify({
                "error": "Database constraint violation",
                "details": str(e.orig)
            }), 409

        except SQLAlchemyError as e:
            db.session.rollback()
            app.logger.error(f"Database error creating product: {str(e)}")
            return jsonify({
                "error": "Database error occurred",
                "message": "Please try again or contact support"
            }), 500

    except Exception as e:
        db.session.rollback()
        app.logger.error(f"Unexpected error in create_product: {str(e)}")
        return jsonify({
            "error": "An unexpected error occurred",
            "message": "Please contact support"
        }), 500
