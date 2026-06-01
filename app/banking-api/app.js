const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');

const app = express();
app.use(express.json());
app.use(cors());

// ── Database Connection ────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST     || 'localhost',
  port:     parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME     || 'bankingdb',
  user:     process.env.DB_USER     || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// ── Init Tables ────────────────────────────────────────────
const initDB = async () => {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS accounts (
      id          SERIAL PRIMARY KEY,
      owner       VARCHAR(100) NOT NULL,
      balance     DECIMAL(12,2) DEFAULT 0.00,
      created_at  TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS transactions (
      id           SERIAL PRIMARY KEY,
      from_account INT REFERENCES accounts(id),
      to_account   INT REFERENCES accounts(id),
      amount       DECIMAL(12,2) NOT NULL,
      note         VARCHAR(200),
      status       VARCHAR(20) DEFAULT 'completed',
      created_at   TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  // Seed data if empty
  const { rows } = await pool.query('SELECT COUNT(*) FROM accounts');
  if (parseInt(rows[0].count) === 0) {
    await pool.query(`
      INSERT INTO accounts (owner, balance) VALUES
        ('Ahmed Mohamed',  10000.00),
        ('Sara Ali',        5000.00),
        ('Omar Hassan',    20000.00)
    `);
    console.log('Seed data inserted');
  }
  console.log('Database ready');
};

// ── Health & Readiness ─────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', version: process.env.APP_VERSION || 'v1.0', timestamp: new Date() });
});

app.get('/ready', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ready', db: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'not_ready', db: 'disconnected', error: err.message });
  }
});

// ── Stats (for dashboard) ──────────────────────────────────
app.get('/api/stats', async (_req, res) => {
  try {
    const accRes = await pool.query('SELECT COUNT(*) as cnt, COALESCE(SUM(balance),0) as total FROM accounts');
    const txnRes = await pool.query('SELECT COUNT(*) as cnt FROM transactions');
    res.json({
      total_accounts:    parseInt(accRes.rows[0].cnt),
      total_balance:     parseFloat(accRes.rows[0].total),
      total_transactions: parseInt(txnRes.rows[0].cnt),
      api_version:       process.env.APP_VERSION || 'v1.0',
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── Accounts ───────────────────────────────────────────────
app.get('/api/accounts', async (_req, res) => {
  try {
    const result = await pool.query('SELECT * FROM accounts ORDER BY created_at DESC');
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/accounts', async (req, res) => {
  try {
    const { owner, initial_balance = 0 } = req.body;
    if (!owner) return res.status(400).json({ error: 'owner is required' });
    const result = await pool.query(
      'INSERT INTO accounts (owner, balance) VALUES ($1, $2) RETURNING *',
      [owner, initial_balance]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── Transactions ───────────────────────────────────────────
app.get('/api/transactions', async (_req, res) => {
  try {
    const result = await pool.query(`
      SELECT t.*,
             fa.owner AS from_owner,
             ta.owner AS to_owner
      FROM transactions t
      JOIN accounts fa ON t.from_account = fa.id
      JOIN accounts ta ON t.to_account   = ta.id
      ORDER BY t.created_at DESC
      LIMIT 50
    `);
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/transactions', async (req, res) => {
  const { from_account, to_account, amount, note } = req.body;
  const maxLimit = parseFloat(process.env.MAX_TRANSACTION_LIMIT || '50000');

  if (!from_account || !to_account || !amount)
    return res.status(400).json({ error: 'from_account, to_account and amount are required' });
  if (from_account === to_account)
    return res.status(400).json({ error: 'Cannot transfer to same account' });
  if (amount <= 0)
    return res.status(400).json({ error: 'Amount must be positive' });
  if (amount > maxLimit)
    return res.status(400).json({ error: `Amount exceeds limit of ${maxLimit}` });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const fromAcc = await client.query(
      'SELECT id, balance FROM accounts WHERE id=$1 FOR UPDATE', [from_account]
    );
    const toAcc = await client.query(
      'SELECT id FROM accounts WHERE id=$1 FOR UPDATE', [to_account]
    );
    if (!fromAcc.rows[0]) throw new Error('Source account not found');
    if (!toAcc.rows[0])   throw new Error('Destination account not found');
    if (parseFloat(fromAcc.rows[0].balance) < amount)
      throw new Error('Insufficient balance');

    await client.query('UPDATE accounts SET balance=balance-$1 WHERE id=$2', [amount, from_account]);
    await client.query('UPDATE accounts SET balance=balance+$1 WHERE id=$2', [amount, to_account]);
    const txn = await client.query(
      'INSERT INTO transactions (from_account, to_account, amount, note) VALUES ($1,$2,$3,$4) RETURNING *',
      [from_account, to_account, amount, note || null]
    );
    await client.query('COMMIT');
    res.status(201).json(txn.rows[0]);
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(400).json({ error: err.message });
  } finally {
    client.release();
  }
});

// ── Start ──────────────────────────────────────────────────
const PORT = parseInt(process.env.PORT || '3000');
app.listen(PORT, async () => {
  console.log(`Banking API v${process.env.APP_VERSION || '1.0'} listening on :${PORT}`);
  console.log(`DB_HOST=${process.env.DB_HOST}, LOG_LEVEL=${process.env.API_LOG_LEVEL}`);
  try {
    await initDB();
  } catch (err) {
    console.error('DB init failed:', err.message);
  }
});
