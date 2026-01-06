-- =====================================================
-- CORE ENTITIES
-- =====================================================

-- Companies (tenants)
CREATE TABLE companies (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    email           VARCHAR(255),
    phone           VARCHAR(50),
    address         TEXT,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_active       BOOLEAN DEFAULT TRUE
);

CREATE INDEX idx_companies_active ON companies(is_active) WHERE is_active = TRUE;

-- Warehouses belonging to companies
CREATE TABLE warehouses (
    id              BIGSERIAL PRIMARY KEY,
    company_id      BIGINT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    name            VARCHAR(255) NOT NULL,
    address         TEXT,
    city            VARCHAR(100),
    country         VARCHAR(100),
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_warehouse_name_per_company UNIQUE (company_id, name)
);

CREATE INDEX idx_warehouses_company ON warehouses(company_id);
CREATE INDEX idx_warehouses_active ON warehouses(company_id, is_active) WHERE is_active = TRUE;

-- Product categories (optional, for organization)
CREATE TABLE product_categories (
    id              BIGSERIAL PRIMARY KEY,
    company_id      BIGINT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    name            VARCHAR(255) NOT NULL,
    parent_id       BIGINT REFERENCES product_categories(id) ON DELETE SET NULL,
    low_stock_threshold_default INTEGER DEFAULT 10,  -- Default threshold for this category
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_category_name_per_company UNIQUE (company_id, name)
);

CREATE INDEX idx_categories_company ON product_categories(company_id);

-- =====================================================
-- PRODUCTS
-- =====================================================

CREATE TABLE products (
    id              BIGSERIAL PRIMARY KEY,
    company_id      BIGINT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    category_id     BIGINT REFERENCES product_categories(id) ON DELETE SET NULL,
    sku             VARCHAR(50) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    price           DECIMAL(12, 2),  -- Up to 9,999,999,999.99
    cost_price      DECIMAL(12, 2),  -- For margin calculations
    unit_of_measure VARCHAR(20) DEFAULT 'unit',  -- unit, kg, liter, etc.
    is_bundle       BOOLEAN DEFAULT FALSE,
    is_active       BOOLEAN DEFAULT TRUE,
    low_stock_threshold INTEGER,  -- Override category default if set
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- SKU unique within a company
    CONSTRAINT uq_sku_per_company UNIQUE (company_id, sku)
);

CREATE INDEX idx_products_company ON products(company_id);
CREATE INDEX idx_products_sku ON products(company_id, sku);
CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_products_active ON products(company_id, is_active) WHERE is_active = TRUE;
CREATE INDEX idx_products_bundle ON products(company_id) WHERE is_bundle = TRUE;

-- Bundle components (for products that are bundles)
CREATE TABLE bundle_components (
    id              BIGSERIAL PRIMARY KEY,
    bundle_id       BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    component_id    BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    quantity        INTEGER NOT NULL DEFAULT 1,
    
    -- Prevent circular references and duplicates
    CONSTRAINT uq_bundle_component UNIQUE (bundle_id, component_id),
    CONSTRAINT chk_not_self_reference CHECK (bundle_id != component_id),
    CONSTRAINT chk_positive_quantity CHECK (quantity > 0)
);

CREATE INDEX idx_bundle_components_bundle ON bundle_components(bundle_id);
CREATE INDEX idx_bundle_components_component ON bundle_components(component_id);

-- =====================================================
-- SUPPLIERS
-- =====================================================

CREATE TABLE suppliers (
    id              BIGSERIAL PRIMARY KEY,
    company_id      BIGINT NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    name            VARCHAR(255) NOT NULL,
    contact_name    VARCHAR(255),
    contact_email   VARCHAR(255),
    contact_phone   VARCHAR(50),
    address         TEXT,
    lead_time_days  INTEGER,  -- Average delivery time
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_supplier_name_per_company UNIQUE (company_id, name)
);

CREATE INDEX idx_suppliers_company ON suppliers(company_id);
CREATE INDEX idx_suppliers_active ON suppliers(company_id, is_active) WHERE is_active = TRUE;

-- Products supplied by suppliers (many-to-many)
CREATE TABLE product_suppliers (
    id              BIGSERIAL PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    supplier_id     BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    supplier_sku    VARCHAR(50),  -- Supplier's SKU for this product
    unit_cost       DECIMAL(12, 2),  -- Cost from this supplier
    min_order_qty   INTEGER DEFAULT 1,
    is_preferred    BOOLEAN DEFAULT FALSE,  -- Primary supplier for this product
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT uq_product_supplier UNIQUE (product_id, supplier_id)
);

CREATE INDEX idx_product_suppliers_product ON product_suppliers(product_id);
CREATE INDEX idx_product_suppliers_supplier ON product_suppliers(supplier_id);
CREATE INDEX idx_product_suppliers_preferred ON product_suppliers(product_id) WHERE is_preferred = TRUE;

-- =====================================================
-- INVENTORY
-- =====================================================

-- Current inventory levels (denormalized for fast reads)
CREATE TABLE inventory (
    id              BIGSERIAL PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id    BIGINT NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    quantity        INTEGER NOT NULL DEFAULT 0,
    reserved_qty    INTEGER NOT NULL DEFAULT 0,  -- Reserved for pending orders
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- One inventory record per product-warehouse combination
    CONSTRAINT uq_product_warehouse UNIQUE (product_id, warehouse_id),
    CONSTRAINT chk_non_negative_qty CHECK (quantity >= 0),
    CONSTRAINT chk_non_negative_reserved CHECK (reserved_qty >= 0),
    CONSTRAINT chk_reserved_not_exceed CHECK (reserved_qty <= quantity)
);

CREATE INDEX idx_inventory_product ON inventory(product_id);
CREATE INDEX idx_inventory_warehouse ON inventory(warehouse_id);
CREATE INDEX idx_inventory_low_stock ON inventory(warehouse_id, quantity);  -- For low stock queries

-- Inventory change history (audit trail)
CREATE TABLE inventory_transactions (
    id              BIGSERIAL PRIMARY KEY,
    inventory_id    BIGINT NOT NULL REFERENCES inventory(id) ON DELETE CASCADE,
    product_id      BIGINT NOT NULL,  -- Denormalized for faster queries
    warehouse_id    BIGINT NOT NULL,  -- Denormalized for faster queries
    transaction_type VARCHAR(50) NOT NULL,  -- 'purchase', 'sale', 'adjustment', 'transfer_in', 'transfer_out'
    quantity_change INTEGER NOT NULL,  -- Positive for additions, negative for removals
    quantity_before INTEGER NOT NULL,
    quantity_after  INTEGER NOT NULL,
    reference_type  VARCHAR(50),  -- 'order', 'purchase_order', 'manual', 'transfer'
    reference_id    BIGINT,  -- ID of related order/PO/transfer
    notes           TEXT,
    created_by      BIGINT,  -- User ID who made the change
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_inv_trans_inventory ON inventory_transactions(inventory_id);
CREATE INDEX idx_inv_trans_product ON inventory_transactions(product_id);
CREATE INDEX idx_inv_trans_warehouse ON inventory_transactions(warehouse_id);
CREATE INDEX idx_inv_trans_created ON inventory_transactions(created_at DESC);
CREATE INDEX idx_inv_trans_type ON inventory_transactions(transaction_type);
CREATE INDEX idx_inv_trans_reference ON inventory_transactions(reference_type, reference_id);

-- =====================================================
-- SALES TRACKING (for low-stock calculations)
-- =====================================================

-- Aggregated daily sales for velocity calculations
CREATE TABLE daily_sales_summary (
    id              BIGSERIAL PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id    BIGINT NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    sale_date       DATE NOT NULL,
    quantity_sold   INTEGER NOT NULL DEFAULT 0,
    
    CONSTRAINT uq_daily_sales UNIQUE (product_id, warehouse_id, sale_date)
);

CREATE INDEX idx_daily_sales_product ON daily_sales_summary(product_id);
CREATE INDEX idx_daily_sales_date ON daily_sales_summary(sale_date DESC);
CREATE INDEX idx_daily_sales_lookup ON daily_sales_summary(product_id, warehouse_id, sale_date DESC);