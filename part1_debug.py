from flask import request, jsonify
from sqlalchemy.exc import IntegrityError
from decimal import Decimal, InvalidOperation

@app.route('/api/products', methods=['POST'])
def create_product():
    """
    Create a new product and optionally initialize inventory in a warehouse.
    
    Required fields: name, sku
    Optional fields: price, warehouse_id, initial_quantity, description
    """
    data = request.json
    
    # Input validation
    if not data:
        return jsonify({"error": "Request body is required"}), 400
    
    # Validate required fields
    required_fields = ['name', 'sku']
    missing_fields = [f for f in required_fields if not data.get(f)]
    if missing_fields:
        return jsonify({
            "error": f"Missing required fields: {', '.join(missing_fields)}"
        }), 400
    
    # Validate SKU format (example: alphanumeric with dashes)
    sku = data['sku'].strip().upper()
    if not sku or len(sku) > 50:
        return jsonify({"error": "SKU must be 1-50 characters"}), 400
    
    # Check SKU uniqueness before attempting insert
    existing_product = Product.query.filter_by(sku=sku).first()
    if existing_product:
        return jsonify({"error": f"SKU '{sku}' already exists"}), 409  # Conflict
    
    # Validate price if provided
    price = None
    if data.get('price') is not None:
        try:
            price = Decimal(str(data['price']))
            if price < 0:
                return jsonify({"error": "Price cannot be negative"}), 400
        except (InvalidOperation, ValueError):
            return jsonify({"error": "Invalid price format"}), 400
    
    # Validate warehouse and quantity if provided
    warehouse_id = data.get('warehouse_id')
    initial_quantity = data.get('initial_quantity', 0)
    
    if warehouse_id:
        # Verify warehouse exists
        warehouse = Warehouse.query.get(warehouse_id)
        if not warehouse:
            return jsonify({"error": f"Warehouse {warehouse_id} not found"}), 404
        
        # Validate quantity
        try:
            initial_quantity = int(initial_quantity)
            if initial_quantity < 0:
                return jsonify({"error": "Initial quantity cannot be negative"}), 400
        except (ValueError, TypeError):
            return jsonify({"error": "Invalid quantity format"}), 400
    
    try:
        # Use a single transaction for atomicity
        # Note: Product should NOT have warehouse_id - that's handled via Inventory
        product = Product(
            name=data['name'].strip(),
            sku=sku,
            price=price,
            description=data.get('description', '').strip()
        )
        
        db.session.add(product)
        db.session.flush()  # Get product.id without committing
        
        # Create inventory record if warehouse specified
        inventory = None
        if warehouse_id:
            inventory = Inventory(
                product_id=product.id,
                warehouse_id=warehouse_id,
                quantity=initial_quantity
            )
            db.session.add(inventory)
        
        # Single commit for both operations (atomic)
        db.session.commit()
        
        response_data = {
            "message": "Product created successfully",
            "product": {
                "id": product.id,
                "name": product.name,
                "sku": product.sku,
                "price": str(product.price) if product.price else None
            }
        }
        
        if inventory:
            response_data["inventory"] = {
                "warehouse_id": warehouse_id,
                "quantity": initial_quantity
            }
        
        return jsonify(response_data), 201  # Created
        
    except IntegrityError as e:
        db.session.rollback()
        # Handle race condition where SKU was created between check and insert
        if 'sku' in str(e.orig).lower():
            return jsonify({"error": f"SKU '{sku}' already exists"}), 409
        return jsonify({"error": "Database constraint violation"}), 400
        
    except Exception as e:
        db.session.rollback()
        # Log the actual error for debugging (don't expose to user)
        app.logger.error(f"Error creating product: {str(e)}")
        return jsonify({"error": "An unexpected error occurred"}), 500