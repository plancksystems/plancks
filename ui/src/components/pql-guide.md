# PQL Query Language

PQL is Planck's text query language used from the workbench and shell.

**Syntax:** `store.operation(...)`

All examples use the **AdventureWorks sample** dataset (import via the Import feature):

| Store               | Key Fields                                                                           |
| ------------------- | ------------------------------------------------------------------------------------ |
| `orders`            | `EmployeeID` (int), `CustomerID` (int), `TotalDue` (float)                           |
| `employees`         | `EmployeeID` (int), `Gender` (string), `MaritalStatus` (string)                      |
| `products`          | `ProductName` (string), `ListPrice` (float), `SubCategoryID` (int), `MakeFlag` (int) |
| `customers`         | `CustomerID` (int), `Address.City` (string), `Address.State` (string)                |
| `vendors`           | `VendorName` (string), `ActiveFlag` (int), `CreditRating` (int)                      |
| `productcategories` | `CategoryName` (string)                                                              |

---

## 1. Count

```
orders.count()
orders.filter(EmployeeID = 289).count()
vendors.filter(ActiveFlag = 1).count()
products.filter(MakeFlag = 1).count()
```

---

## 2. Filter - Equality

```
employees.filter(Gender = "M").count()
employees.filter(EmployeeID = 274).count()
products.filter(SubCategoryID = 14).count()
productcategories.filter(CategoryName = "Bikes").count()
```

---

## 3. Filter - Comparison Operators

Operators: `>` `<` `>=` `<=` `!=`

```
orders.filter(TotalDue > 50000).count()
orders.filter(TotalDue < 100).count()
orders.filter(TotalDue >= 100000).count()
products.filter(ListPrice > 1000).count()
vendors.filter(CreditRating != 1).count()
```

---

## 4. Compound Filters (AND)

```
orders.filter(EmployeeID = 289 and CustomerID = 1045).count()
employees.filter(Gender = "M" and MaritalStatus = "M").count()
orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()
```

---

## 5. Limit & Skip

```
orders.limit(10).count()
orders.skip(3800).count()
customers.limit(100).count()
```

---

## 6. OrderBy (Sorting)

```
products.orderBy(ListPrice, desc).limit(5)
products.orderBy(ListPrice, asc).limit(5)
employees.orderBy(EmployeeID, asc).limit(3)
employees.orderBy(EmployeeID, desc).limit(3)
```

---

## 7. Multi-Sort

```
orders.orderBy(EmployeeID, asc).orderBy(TotalDue, desc).limit(10)
employees.orderBy(Gender, asc).orderBy(EmployeeID, desc).limit(10)

// With filter
orders.filter(EmployeeID >= 285).orderBy(EmployeeID, asc).orderBy(TotalDue, asc).limit(20)
```

---

## 8. Projection (pluck)

Return only specific fields:

```
employees.filter(EmployeeID = 274).pluck(EmployeeID, FullName)
products.filter(SubCategoryID = 14).limit(1).pluck(ProductName, ListPrice)
employees.limit(1).pluck(EmployeeID)
orders.filter(EmployeeID = 289).orderBy(TotalDue, desc).limit(1).pluck(EmployeeID, TotalDue)
```

---

## 9. Aggregation - Count

```
orders.aggregate(total: count)
orders.filter(EmployeeID = 289).aggregate(total: count)
products.filter(MakeFlag = 1).aggregate(n: count)
```

---

## 10. Aggregation - Sum, Avg, Min, Max

```
orders.aggregate(total: sum(TotalDue))
orders.aggregate(avg_total: avg(TotalDue))
orders.aggregate(min_total: min(TotalDue))
orders.aggregate(max_total: max(TotalDue))

// With filter
orders.filter(EmployeeID = 289).aggregate(revenue: sum(TotalDue))
```

---

## 11. GroupBy

```
orders.groupBy(EmployeeID).aggregate(n: count)
employees.groupBy(Gender).aggregate(n: count)
employees.groupBy(Gender, MaritalStatus).aggregate(n: count)
orders.groupBy(EmployeeID).aggregate(n: count, total: sum(TotalDue))
```

---

## 12. Filter + GroupBy

```
orders.filter(TotalDue > 10000).groupBy(EmployeeID).aggregate(n: count)
products.filter(ListPrice > 0).groupBy(SubCategoryID).aggregate(n: count, avg_price: avg(ListPrice))
orders.filter(EmployeeID = 289).groupBy(CustomerID).aggregate(n: count, total: sum(TotalDue))
```

---

## 13. $in Operator

```
orders.filter(EmployeeID in [289, 288]).count()
orders.filter(EmployeeID in [289, 287, 285]).count()
products.filter(SubCategoryID in [1, 2, 14]).count()
employees.filter(Gender in ["M"]).count()
```

---

## 14. $contains Operator

```
products.filter(ProductName contains "Road").count()
products.filter(ProductName contains "Mountain").count()
products.filter(ProductName contains "Frame").count()
vendors.filter(VendorName contains "Bike").count()
```

---

## 15. $startsWith Operator

```
products.filter(ProductName startsWith "HL").count()
products.filter(ProductName startsWith "Mountain").count()
employees.filter(FirstName startsWith "S").count()
```

---

## 16. $exists Operator

```
products.filter(ProductName exists true).count()
employees.filter(Gender exists true).count()
```

---

## 17. $regex Operator

Use `~` as the regex operator:

```
products.filter(ProductName ~ "^HL").count()
products.filter(ProductName ~ "Frame").count()
products.filter(ProductName ~ "58$").count()
products.filter(ProductName ~ "^AWC Logo Cap$").count()
```

---

## 18. OR Filters

```
employees.filter(Gender = "M" or MaritalStatus = "S").count()
products.filter(ProductName contains "Road" or ProductName contains "Mountain").count()
products.filter(SubCategoryID = 1 or SubCategoryID = 2).count()
orders.filter(TotalDue > 100000 or TotalDue < 100).count()
orders.filter(EmployeeID = 289 or EmployeeID = 288).count()
```

---

## 19. Range Scans

```
// Closed range
orders.filter(EmployeeID >= 285 and EmployeeID <= 287).count()

// Open range
orders.filter(EmployeeID > 285 and EmployeeID < 289).count()

// One-sided
orders.filter(EmployeeID > 288).count()
orders.filter(EmployeeID < 285).count()
```

---

## 20. $between Operator

Inclusive range match - equivalent to `field >= lower and field <= upper`, but more concise and directly mapped to a B+ tree range scan when the field is indexed:

```
orders.filter(TotalDue between 100 and 5000).count()
products.filter(ListPrice between 10.0 and 50.0).count()
employees.filter(EmployeeID between 280 and 290).count()

// Combined with other conditions
products.filter(ListPrice between 10.0 and 50.0 and MakeFlag = 1).count()
orders.filter(EmployeeID between 285 and 289).orderBy(TotalDue, desc).limit(10)
```

Both bounds are **inclusive**. Works on numeric fields.

---

## 21. Nested Field Access

Use dot notation for embedded documents:

```
customers.filter(Address.City = "New York").count()
customers.filter(Address.State = "CA").count()
customers.filter(Address.Country = "US").count()
customers.filter(Address.City = "Seattle").count()
```

---

## 22. Insert

```
products.insert({"ProductID": 9001, "ProductName": "Test Widget", "ListPrice": 99.99, "SubCategoryID": 1})
vendors.insert({"VendorID": 9001, "VendorName": "Test Vendor", "CreditRating": 3, "ActiveFlag": 1})
productcategories.insert({"CategoryID": 99, "CategoryName": "TestCategory"})
```

---

## 23. Update (set)

Use `.filter().set({fields})` - only specified fields are updated:

```
products.filter(ProductID = 9001).set({"ListPrice": 149.99})
vendors.filter(VendorName = "Test Vendor").set({"CreditRating": 5})
products.filter(MakeFlag = 1 and ListPrice > 100).set({"StandardCost": 75.00})
products.filter(ProductID = 9001).set({"ListPrice": 199.99, "StandardCost": 80.00})
```

---

## 24. Delete

```
products.filter(ProductID = 9001).delete()
vendors.filter(ActiveFlag = 0).delete()
products.filter(MakeFlag = 0 and ListPrice < 5).delete()
```

---

## 25. Get by Key

Direct primary-key lookup. Maps to `Operation.Read`, bypassing the
filter engine, so this is the fastest path for a known-key read.
The key is the 32-char hex `key` field that engine query results
return at the top of every document. Both bare hex and `0x`-prefixed
hex are accepted.

```
products.limit(1)
products.get(00680400000018b8434c192c4f880000)
products.get(0x00680400000018b8434c192c4f880000)
```

Run `products.limit(1)` to copy a real key from your data, then paste
it into `get(...)`.

---

## 26. Delete by Key

Symmetric to `get`: delete one document by primary key without
scanning. Use `filter(...).delete()` for predicate-based deletes.

```
products.delete(00680400000018b8434c192c4f880000)
```

---

## Operator Reference

### Filter Operators

| Operator         | Syntax             | Description           |
| ---------------- | ------------------ | --------------------- |
| Equal            | `=`                | Exact match           |
| Not Equal        | `!=`               | Not equal             |
| Greater Than     | `>`                | Greater than          |
| Greater or Equal | `>=`               | Greater than or equal |
| Less Than        | `<`                | Less than             |
| Less or Equal    | `<=`               | Less than or equal    |
| In               | `in [...]`         | Value in list         |
| Between          | `between A and B`  | Inclusive range       |
| Contains         | `contains "..."`   | Substring match       |
| Starts With      | `startsWith "..."` | Prefix match          |
| Exists           | `exists true`      | Field exists check    |
| Regex            | `~ "pattern"`      | Regex match           |

### Logical Operators

| Operator | Syntax |
| -------- | ------ |
| AND      | `and`  |
| OR       | `or`   |

### Aggregation Functions

| Function | Syntax                         |
| -------- | ------------------------------ |
| Count    | `aggregate(alias: count)`      |
| Sum      | `aggregate(alias: sum(field))` |
| Average  | `aggregate(alias: avg(field))` |
| Minimum  | `aggregate(alias: min(field))` |
| Maximum  | `aggregate(alias: max(field))` |

### Query Modifiers

| Modifier   | Syntax                      |
| ---------- | --------------------------- |
| Limit      | `.limit(N)`                 |
| Skip       | `.skip(N)`                  |
| Order By   | `.orderBy(field, asc/desc)` |
| Group By   | `.groupBy(field)`           |
| Projection | `.pluck(field1, field2)`    |
| Count Only | `.count()`                  |

---

## Query Chaining Order

```
space.store
  .filter(...)           // optional filter (and/or)
  .orderBy(field, dir)   // optional sort (chainable)
  .limit(N)              // optional limit
  .skip(N)               // optional offset
  .pluck(field1, ...)    // optional projection
  .count()               // count only
  .aggregate(...)        // aggregation
  .groupBy(field)        // group by
  .insert({...})         // mutation: insert
  .set({...})            // mutation: update
  .delete()              // mutation: delete
```

## Secondary Index Usage

Queries automatically use secondary indexes when available:

- **Equality** (`=`) - exact key lookup
- **Range** (`>`, `>=`, `<`, `<=`) - B+ tree range scan
- **Between** (`between A and B`) - B+ tree range scan (inclusive)
- **$in** - multi-key lookup

Operators that **always require full scan**:

- `contains`, `startsWith`, `~` (regex)
- `exists`
- `!=`
- Queries with no filter
