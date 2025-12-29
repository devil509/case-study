 Database Schema Design : 

 

-- ============================================ 

-- ORGANIZATIONS & USER MANAGEMENT 

-- ============================================ 

 

CREATE TABLE organizations ( 

    id SERIAL PRIMARY KEY, 

    name VARCHAR(255) NOT NULL, 

    slug VARCHAR(100) UNIQUE NOT NULL, 

    subscription_tier VARCHAR(50) DEFAULT 'free', 

    sku_case_sensitive BOOLEAN DEFAULT FALSE, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    is_active BOOLEAN DEFAULT TRUE 

); 

 

CREATE INDEX idx_organizations_slug ON organizations(slug); 

CREATE INDEX idx_organizations_active ON organizations(is_active); 

 

CREATE TABLE users ( 

    id SERIAL PRIMARY KEY, 

    organization_id INTEGER NOT NULL REFERENCES organizations(id), 

    email VARCHAR(255) NOT NULL UNIQUE, 

    password_hash VARCHAR(255) NOT NULL, 

    first_name VARCHAR(100), 

    last_name VARCHAR(100), 

    role VARCHAR(50) NOT NULL DEFAULT 'user', -- admin, manager, user, viewer 

    is_active BOOLEAN DEFAULT TRUE, 

    last_login_at TIMESTAMP, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW() 

); 

 

CREATE INDEX idx_users_org_id ON users(organization_id); 

CREATE INDEX idx_users_email ON users(email); 

CREATE INDEX idx_users_active ON users(organization_id, is_active); 

 

-- ============================================ 

-- WAREHOUSE MANAGEMENT 

-- ============================================ 

 

CREATE TABLE warehouses ( 

    id SERIAL PRIMARY KEY, 

    organization_id INTEGER NOT NULL REFERENCES organizations(id), 

    name VARCHAR(255) NOT NULL, 

    code VARCHAR(50), -- Short identifier like "WH-NYC-01" 

    address_line1 VARCHAR(255), 

    address_line2 VARCHAR(255), 

    city VARCHAR(100), 

    state_province VARCHAR(100), 

    postal_code VARCHAR(20), 

    country VARCHAR(2), -- ISO country code 

    contact_name VARCHAR(100), 

    contact_phone VARCHAR(20), 

    contact_email VARCHAR(255), 

    is_active BOOLEAN DEFAULT TRUE, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    created_by INTEGER REFERENCES users(id), 

     

    CONSTRAINT unique_warehouse_code_per_org UNIQUE(organization_id, code) 

); 

 

CREATE INDEX idx_warehouses_org_id ON warehouses(organization_id); 

CREATE INDEX idx_warehouses_active ON warehouses(organization_id, is_active); 

 

-- ============================================ 

-- SUPPLIER MANAGEMENT 

-- ============================================ 

 

CREATE TABLE suppliers ( 

    id SERIAL PRIMARY KEY, 

    organization_id INTEGER NOT NULL REFERENCES organizations(id), 

    name VARCHAR(255) NOT NULL, 

    code VARCHAR(50), -- Internal supplier code 

    contact_name VARCHAR(100), 

    contact_email VARCHAR(255), 

    contact_phone VARCHAR(20), 

    address_line1 VARCHAR(255), 

    address_line2 VARCHAR(255), 

    city VARCHAR(100), 

    state_province VARCHAR(100), 

    postal_code VARCHAR(20), 

    country VARCHAR(2), 

    payment_terms VARCHAR(100), -- "Net 30", "Net 60", etc. 

    currency VARCHAR(3) DEFAULT 'USD', -- ISO currency code 

    tax_id VARCHAR(50), -- For tax/compliance 

    notes TEXT, 

    is_active BOOLEAN DEFAULT TRUE, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    created_by INTEGER REFERENCES users(id), 

     

    CONSTRAINT unique_supplier_code_per_org UNIQUE(organization_id, code) 

); 

 

CREATE INDEX idx_suppliers_org_id ON suppliers(organization_id); 

CREATE INDEX idx_suppliers_active ON suppliers(organization_id, is_active); 

 

-- ============================================ 

-- PRODUCT MANAGEMENT 

-- ============================================ 

 

CREATE TABLE products ( 

    id SERIAL PRIMARY KEY, 

    organization_id INTEGER NOT NULL REFERENCES organizations(id), 

    sku VARCHAR(100) NOT NULL, -- Original SKU as entered 

    sku_normalized VARCHAR(100) NOT NULL, -- Uppercase, no spaces for uniqueness 

    name VARCHAR(255) NOT NULL, 

    description TEXT, 

    product_type VARCHAR(50) DEFAULT 'simple', -- simple, bundle, variant 

    category VARCHAR(100), -- Electronics, Apparel, etc. 

    unit_of_measure VARCHAR(20) DEFAULT 'each', -- each, box, pallet, kg, lb 

     

    -- Pricing 

    cost_price DECIMAL(15, 4), -- What we pay supplier 

    sale_price DECIMAL(15, 4), -- What we sell for 

    currency VARCHAR(3) DEFAULT 'USD', 

     

    -- Physical attributes 

    weight DECIMAL(10, 4), 

    weight_unit VARCHAR(10), -- kg, lb, g 

    length DECIMAL(10, 2), 

    width DECIMAL(10, 2), 

    height DECIMAL(10, 2), 

    dimension_unit VARCHAR(10), -- cm, in, m 

     

    -- Inventory settings 

    low_stock_threshold INTEGER DEFAULT 10, 

    reorder_point INTEGER, 

    reorder_quantity INTEGER, 

     

 

    -- Soft delete and audit 

    is_deleted BOOLEAN DEFAULT FALSE, 

    deleted_at TIMESTAMP, 

    deleted_by INTEGER REFERENCES users(id), 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    created_by INTEGER REFERENCES users(id), 

    updated_by INTEGER REFERENCES users(id), 

     

    CONSTRAINT unique_sku_per_org UNIQUE(organization_id, sku_normalized) 

); 

 

CREATE INDEX idx_products_org_id ON products(organization_id); 

CREATE INDEX idx_products_sku ON products(organization_id, sku_normalized); 

CREATE INDEX idx_products_active ON products(organization_id, is_deleted) WHERE is_deleted = FALSE; 

CREATE INDEX idx_products_type ON products(product_type); 

CREATE INDEX idx_products_category ON products(organization_id, category); 

CREATE INDEX idx_products_barcode ON products(barcode) WHERE barcode IS NOT NULL; 

 

-- Full-text search on product name and description 

CREATE INDEX idx_products_search ON products USING GIN( 

    to_tsvector('english', COALESCE(name, '') || ' ' || COALESCE(description, '')) 

); 

 

 

 

 

-- ============================================ 

-- PRODUCT-SUPPLIER RELATIONSHIPS 

-- ============================================ 

 

CREATE TABLE product_suppliers ( 

    id SERIAL PRIMARY KEY, 

    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE, 

    supplier_id INTEGER NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE, 

    supplier_sku VARCHAR(100), -- Supplier's SKU for this product 

    cost_price DECIMAL(15, 4), -- Cost from this specific supplier 

    lead_time_days INTEGER, -- How long to get stock from supplier 

    minimum_order_quantity INTEGER, 

    is_preferred BOOLEAN DEFAULT FALSE, -- Preferred supplier for this product 

    notes TEXT, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

     

    CONSTRAINT unique_product_supplier UNIQUE(product_id, supplier_id) 

); 

 

CREATE INDEX idx_product_suppliers_product ON product_suppliers(product_id); 

CREATE INDEX idx_product_suppliers_supplier ON product_suppliers(supplier_id); 

CREATE INDEX idx_product_suppliers_preferred ON product_suppliers(product_id, is_preferred)  

    WHERE is_preferred = TRUE; 

 

 

 

-- ============================================ 

-- PRODUCT BUNDLES (Bill of Materials) 

-- ============================================ 

 

CREATE TABLE product_bundles ( 

    id SERIAL PRIMARY KEY, 

    bundle_product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE, 

    component_product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE, 

    quantity DECIMAL(10, 4) NOT NULL DEFAULT 1, -- Quantity of component in bundle 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

     

    -- Prevent circular dependencies 

    CONSTRAINT no_self_reference CHECK (bundle_product_id != component_product_id), 

    CONSTRAINT unique_bundle_component UNIQUE(bundle_product_id, component_product_id) 

); 

 

CREATE INDEX idx_bundles_bundle_id ON product_bundles(bundle_product_id); 

CREATE INDEX idx_bundles_component_id ON product_bundles(component_product_id); 

 

-- ============================================ 

-- INVENTORY MANAGEMENT 

-- ============================================ 

 

CREATE TABLE inventory ( 

    id SERIAL PRIMARY KEY, 

    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE, 

    warehouse_id INTEGER NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE, 

     

    -- Quantities 

    quantity_available INTEGER NOT NULL DEFAULT 0, -- Available for sale 

    quantity_reserved INTEGER NOT NULL DEFAULT 0, -- Reserved for orders 

    quantity_damaged INTEGER NOT NULL DEFAULT 0, -- Damaged/unsellable 

    quantity_in_transit INTEGER NOT NULL DEFAULT 0, -- Being transferred 

     

    -- Calculated: Total physical stock 

    -- quantity_on_hand = quantity_available + quantity_reserved + quantity_damaged 

    -- Timestamps 

    last_counted_at TIMESTAMP, -- Last physical count 

    last_counted_by INTEGER REFERENCES users(id), 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

     

    CONSTRAINT unique_product_warehouse UNIQUE(product_id, warehouse_id), 

    CONSTRAINT non_negative_available CHECK (quantity_available >= 0), 

    CONSTRAINT non_negative_reserved CHECK (quantity_reserved >= 0), 

    CONSTRAINT non_negative_damaged CHECK (quantity_damaged >= 0) 

); 

 

CREATE INDEX idx_inventory_product ON inventory(product_id); 

CREATE INDEX idx_inventory_warehouse ON inventory(warehouse_id); 

CREATE INDEX idx_inventory_low_stock ON inventory(product_id, warehouse_id, quantity_available); 

 

 

 

-- View for total available inventory across all warehouses 

CREATE VIEW product_total_inventory AS 

SELECT  

    product_id, 

    SUM(quantity_available) as total_available, 

    SUM(quantity_reserved) as total_reserved, 

    SUM(quantity_damaged) as total_damaged, 

    SUM(quantity_available + quantity_reserved + quantity_damaged) as total_on_hand 

FROM inventory 

GROUP BY product_id; 

 

-- ============================================ 

-- INVENTORY TRANSACTION HISTORY 

-- ============================================ 

 

CREATE TABLE inventory_transactions ( 

    id BIGSERIAL PRIMARY KEY, -- BIGSERIAL for high volume 

    product_id INTEGER NOT NULL REFERENCES products(id), 

    warehouse_id INTEGER NOT NULL REFERENCES warehouses(id), 

     

    -- Transaction details 

    transaction_type VARCHAR(50) NOT NULL,  

    -- Types: purchase, sale, adjustment, transfer_in, transfer_out,  

    --        return, damage, recount, manufacturing 

     

    quantity_change INTEGER NOT NULL, -- Positive or negative 

    quantity_before INTEGER NOT NULL, 

    quantity_after INTEGER NOT NULL, 

     

    -- Cost tracking 

    unit_cost DECIMAL(15, 4), 

    total_cost DECIMAL(15, 4), 

     

    -- Reference data 

    reference_type VARCHAR(50), -- purchase_order, sales_order, transfer, adjustment 

    reference_id INTEGER, -- ID of related record 

    -- Audit 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    created_by INTEGER NOT NULL REFERENCES users(id) 

); 

 

CREATE INDEX idx_inv_trans_product ON inventory_transactions(product_id); 

CREATE INDEX idx_inv_trans_warehouse ON inventory_transactions(warehouse_id); 

CREATE INDEX idx_inv_trans_type ON inventory_transactions(transaction_type); 

CREATE INDEX idx_inv_trans_created ON inventory_transactions(created_at DESC); 

CREATE INDEX idx_inv_trans_reference ON inventory_transactions(reference_type, reference_id); 

 

 

 

 

 

 

 

 

-- ============================================ 

-- PURCHASE ORDERS (for supplier restocking) 

-- ============================================ 

 

CREATE TABLE purchase_orders ( 

    id SERIAL PRIMARY KEY, 

    organization_id INTEGER NOT NULL REFERENCES organizations(id), 

    supplier_id INTEGER NOT NULL REFERENCES suppliers(id), 

    warehouse_id INTEGER NOT NULL REFERENCES warehouses(id), -- Destination warehouse 

     

    po_number VARCHAR(50) NOT NULL, -- Human-readable PO number 

    status VARCHAR(50) NOT NULL DEFAULT 'draft',  

    -- draft, submitted, approved, partially_received, received, cancelled 

     

    order_date DATE NOT NULL, 

    expected_delivery_date DATE, 

    actual_delivery_date DATE, 

     

    -- Totals 

    subtotal DECIMAL(15, 4), 

    tax_amount DECIMAL(15, 4), 

    shipping_cost DECIMAL(15, 4), 

    total_amount DECIMAL(15, 4), 

    currency VARCHAR(3) DEFAULT 'USD', 

     

    notes TEXT, 

    terms TEXT, -- Payment terms, delivery terms 

     

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    created_by INTEGER REFERENCES users(id), 

    approved_by INTEGER REFERENCES users(id), 

    approved_at TIMESTAMP, 

     

    CONSTRAINT unique_po_number_per_org UNIQUE(organization_id, po_number) 

); 

 

CREATE INDEX idx_po_org_id ON purchase_orders(organization_id); 

CREATE INDEX idx_po_supplier ON purchase_orders(supplier_id); 

CREATE INDEX idx_po_status ON purchase_orders(status); 

CREATE INDEX idx_po_dates ON purchase_orders(order_date, expected_delivery_date); 

 

CREATE TABLE purchase_order_items ( 

    id SERIAL PRIMARY KEY, 

    purchase_order_id INTEGER NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE, 

    product_id INTEGER NOT NULL REFERENCES products(id), 

     

    quantity_ordered INTEGER NOT NULL, 

    quantity_received INTEGER NOT NULL DEFAULT 0, 

     

    unit_cost DECIMAL(15, 4) NOT NULL, 

    line_total DECIMAL(15, 4) NOT NULL, 

     

    notes TEXT, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

     

    CONSTRAINT positive_quantity CHECK (quantity_ordered > 0) 

); 

 

CREATE INDEX idx_po_items_po ON purchase_order_items(purchase_order_id); 

CREATE INDEX idx_po_items_product ON purchase_order_items(product_id); 

 

-- ============================================ 

-- WAREHOUSE TRANSFERS 

-- ============================================ 

 

CREATE TABLE warehouse_transfers ( 

    id SERIAL PRIMARY KEY, 

    organization_id INTEGER NOT NULL REFERENCES organizations(id), 

    from_warehouse_id INTEGER NOT NULL REFERENCES warehouses(id), 

    to_warehouse_id INTEGER NOT NULL REFERENCES warehouses(id), 

     

    transfer_number VARCHAR(50) NOT NULL, 

    status VARCHAR(50) NOT NULL DEFAULT 'pending', 

    -- pending, in_transit, completed, cancelled 

     

    initiated_date TIMESTAMP NOT NULL DEFAULT NOW(), 

    shipped_date TIMESTAMP, 

    received_date TIMESTAMP, 

     

    notes TEXT, 

     

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    updated_at TIMESTAMP NOT NULL DEFAULT NOW(), 

    created_by INTEGER REFERENCES users(id), 

    shipped_by INTEGER REFERENCES users(id), 

    received_by INTEGER REFERENCES users(id), 

     

    CONSTRAINT different_warehouses CHECK (from_warehouse_id != to_warehouse_id), 

    CONSTRAINT unique_transfer_number UNIQUE(organization_id, transfer_number) 

); 

 

CREATE INDEX idx_transfers_org ON warehouse_transfers(organization_id); 

CREATE INDEX idx_transfers_from ON warehouse_transfers(from_warehouse_id); 

CREATE INDEX idx_transfers_to ON warehouse_transfers(to_warehouse_id); 

CREATE INDEX idx_transfers_status ON warehouse_transfers(status); 

 

CREATE TABLE warehouse_transfer_items ( 

    id SERIAL PRIMARY KEY, 

    transfer_id INTEGER NOT NULL REFERENCES warehouse_transfers(id) ON DELETE CASCADE, 

    product_id INTEGER NOT NULL REFERENCES products(id), 

     

    quantity_requested INTEGER NOT NULL, 

    quantity_shipped INTEGER NOT NULL DEFAULT 0, 

    quantity_received INTEGER NOT NULL DEFAULT 0, 

     

    notes TEXT, 

    created_at TIMESTAMP NOT NULL DEFAULT NOW(), 

     

    CONSTRAINT positive_quantity CHECK (quantity_requested > 0) 

); 

 

CREATE INDEX idx_transfer_items_transfer ON warehouse_transfer_items(transfer_id); 

CREATE INDEX idx_transfer_items_product ON warehouse_transfer_items(product_id); 
