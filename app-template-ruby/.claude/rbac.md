# RBAC & the Authentication Boundary — Roles, Policies, Three Layers

Load this file when adding login/signup, a role check, a policy object, an admin
namespace, or any "can this user do X" decision. This is where the project draws
the line between **who you are**, **which rows you can touch**, and **which
actions you may perform** — and keeps all three out of the route.

> **Baseline:** Authentication via a Rack session cookie (`enable :sessions`,
> secret = `ENV["SECRET_KEY_BASE"]`) + `bcrypt` on a `users` table (a
> `Sequel::Model`); authorization via hand-rolled plain-Ruby policy objects in
> `app/policies/`. Roles on the `Membership` join (per-account). Authorization
> (actions) is separate from tenant scoping (data) and authentication (identity).

Maturity tags: <span title="stable">`[stable]`</span> ship it · <span title="mature">`[mature]`</span> proven, heavier · <span title="emerging">`[emerging]`</span> verify before relying.

---

## The three layers — keep them distinct

This is the conceptual spine. A request passes through all three; each answers a
different question and lives in a different place. **A valid scope still needs
authorization** — being able to *see* a row does not mean you may *act* on it.

| Layer | Question | Where it lives | Failure |
|---|---|---|---|
| **Authentication** | *Who are you?* | A `before` filter reads the Rack session cookie, looks the user up, and sets `Current.user`. | redirect to login / `401` |
| **Tenant scoping** | *Which rows may you touch?* | The current-account dataset (`Current.account.notes_dataset`). See `multi-tenancy.md`. | `404`/`:not_found` (row not in scope) |
| **Authorization** | *Which actions may you perform?* | Plain-Ruby policy objects, checked in the service. | `403`/`:forbidden` |

```ruby
# ❌ collapsing the layers — "found it, so let them edit it"
note = Current.account.notes_dataset.first(id: params[:id])   # scope only
note.update(attrs)                                            # no authorization!

# ✅ scope finds the row; the policy decides the action
note = Current.account.notes_dataset.first(id: params[:id])   # tenant scope
authorize!(note, :update?)                                    # authorization
note.update(attrs)
```

The sibling `separation-of-concerns.md` (lines on `Current` / scope-vs-auth) is
the authority on the route boundary; **this file is the authority on all three
layers together**. Cross-link, don't contradict: scoping rides the account
dataset, authorization rides the policy, both belong in the service. For Sequel
model/dataset mechanics see `database.md`.

---

## 1. Authentication

Authentication establishes identity only. It never decides what an identity may
do — that's authorization (§3). There is no Rails auth generator here; you wire
three small pieces by hand: a signed session cookie, a `bcrypt` digest, and a
`before` filter.

### Session cookie + bcrypt (default) <span title="stable">`[stable]`</span>

Enable Rack's signed cookie session on the modular app and seed the secret from
the environment. Prefer the explicit `Rack::Session::Cookie` form so the flags
are visible:

```ruby
# app.rb
class App < Sinatra::Base
  use Rack::Session::Cookie,
      key:       "my_app.session",
      secret:    ENV.fetch("SECRET_KEY_BASE"),
      same_site: :lax,
      secure:    production?,
      httponly:  true
  # shorthand equivalent: `enable :sessions; set :session_secret, ENV.fetch("SECRET_KEY_BASE")`
end
```

The `User` model hashes with `bcrypt` directly — Sequel ships no
`has_secure_password`, so provide `#password=` and `#authenticate` yourself:

```ruby
# app/models/user.rb
require "bcrypt"

class User < Sequel::Model
  plugin :validation_helpers
  one_to_many :memberships

  def validate
    super
    validates_presence  :email_address
    validates_unique    :email_address
    validates_format    URI::MailTo::EMAIL_REGEXP, :email_address
  end

  def before_validation
    self.email_address = email_address&.strip&.downcase
    super
  end

  def password=(raw)
    self.password_digest = BCrypt::Password.create(raw)
  end

  def authenticate(raw)
    BCrypt::Password.new(password_digest) == raw && self
  end
end
```

`password_digest` is a plain string column (`add_column :users, :password_digest,
String, null: false`). `#authenticate` returns the user on a match and `false`
otherwise, so `user&.authenticate(pw)` reads cleanly.

**Login / logout routes** — thin, no business logic:

```ruby
# app/routes/sessions.rb (registered on App)
get "/session/new" do
  erb :"sessions/new"
end

post "/session" do
  user = User.first(email_address: params[:email].to_s.strip.downcase)
  if user&.authenticate(params[:password].to_s)
    session[:user_id] = user.id     # only the id lives in the cookie
    redirect "/"
  else
    status 401
    erb :"sessions/new"
  end
end

delete "/session" do
  session.delete(:user_id)
  redirect "/session/new"
end
```

**`current_user` helper + the `before` filter** that populates `Current.user`.
`Current` is the DATA boundary (thread/fiber-local), reset before each request
and cleared after — it carries identity, it does not authorize:

```ruby
# app.rb
helpers do
  def current_user
    return nil unless session[:user_id]
    @current_user ||= User[session[:user_id]]
  end

  def require_login!
    redirect "/session/new" unless Current.user
  end
end

before do
  Current.reset                     # clear any leaked state (see separation-of-concerns.md)
  Current.user = current_user       # identity only — no role/permission logic here
end

after { Current.reset }
```

### Warden / OmniAuth (mature alternative) <span title="mature">`[mature]`</span>

Reach for Warden (a Rack authentication framework) when you want pluggable
strategies, and OmniAuth when you need third-party / OAuth login — the rough
equivalent of Devise's confirmable/recoverable/OmniAuth surface, assembled from
parts. Heavier; pin `warden ~> 1.2`, `omniauth ~> 2.1`. To drop the
`#password=`/`#authenticate` boilerplate, the `sequel_secure_password` plugin
(`~> 0.3`) wraps `bcrypt` for you:

```ruby
class User < Sequel::Model
  plugin :secure_password   # from sequel_secure_password; adds #authenticate + password= 
end
```

`bcrypt` remains the building block under every option.

---

## 2. Roles live on the Membership join — never on User

A user belongs to many accounts and holds a **different role per account**. Put
the role on the `Membership` (the `User` ↔ `Account` join), not on `User`.

```ruby
# ❌ role on the user — a global role makes no sense in a multi-account app
class User < Sequel::Model
  # a `role` column here means admin of WHAT? every account?
end

# ✅ role on the membership — scoped to one account
class Membership < Sequel::Model
  many_to_one :user
  many_to_one :account
end
```

Sequel has no ActiveRecord-style `enum`. Store `role` as a string column with a
DB `CHECK` constraint, and declare the hierarchy **low → high** in a frozen
constant so ordered comparison is possible:

```ruby
class Membership < Sequel::Model
  many_to_one :user
  many_to_one :account

  # order matters: ascending rank drives role_at_least?
  ROLES = { "member" => 0, "editor" => 1, "admin" => 2, "owner" => 3 }.freeze

  # predicates: membership.admin?, membership.owner?, …
  ROLES.each_key { |name| define_method("#{name}?") { role == name } }

  # owner > admin > editor > member
  def role_at_least?(min)
    ROLES.fetch(role) >= ROLES.fetch(min.to_s)
  end
end

membership.role_at_least?(:editor)   # admin → true; member → false
```

```ruby
# migration — constrain the column to known roles (see database.md)
Sequel.migration do
  change do
    alter_table(:memberships) do
      add_column :role, String, null: false, default: "member"
      add_constraint(:role_known) { role =~ %w[member editor admin owner] }
    end
  end
end
```

For a richer model (resource-scoped or dynamically assigned roles), keep the same
shape — a `roles` table plus a `memberships_roles` join, resolved through the
membership — but keep roles attached to the membership/account context, not
floating globally on `User`.

**Exactly one owner per account.** SQLite supports partial indexes, so enforce it
in the DB and make ownership transfer an **explicit, audited** action — never a
plain role edit.

```ruby
# migration — partial unique index (SQLite honors the WHERE clause)
Sequel.migration do
  change do
    alter_table(:memberships) do
      add_index :account_id, unique: true, where: "role = 'owner'",
                name: :index_one_owner_per_account
    end
  end
end
```

```ruby
# ✅ transfer is its own service, audited (see architecture-decisions.md)
Accounts::TransferOwnership.call(account:, from:, to:, actor:)
# demotes old owner → admin, promotes new owner, in one short transaction, audited.
# Keep the transaction small: SQLite has a single writer (see database.md).
```

---

## 3. Authorization via plain-Ruby policy objects (default)

Policy classes answer "may this actor do this?". One policy per resource; one
predicate per action. There is **no Pundit gem** — the shape is the same,
hand-rolled: a class in `app/policies/`, `initialize(user, record)`, predicate
methods, and an optional inner `Scope`.

### Policy objects <span title="stable">`[stable]`</span> — the template default

```ruby
# app/policies/note_policy.rb
class NotePolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user, @record = user, record
  end

  def update?
    membership&.role_at_least?(:editor)   # uses the hierarchy helper, §2
  end

  def destroy?
    membership&.role_at_least?(:admin)
  end

  # Scope: which rows may this actor enumerate
  class Scope
    def initialize(user, dataset)
      @user, @dataset = user, dataset
    end

    def resolve
      @dataset.where(account_id: Current.account.id)
    end
  end

  private

  # Look up the membership against the RECORD's account, not Current — so a
  # different-account actor resolves to nil (→ forbidden), and the policy is
  # spec-able in isolation. #first returns nil, never raises.
  def membership
    record.account.memberships_dataset.first(user_id: user.id)
  end
end
```

Wire two helpers onto `App`: `authorize!` (raises via `halt` on denial) and
`policy` / `policy_scope`. `authorize!` is the route-side gate; the service
re-checks (§4):

```ruby
# app.rb
helpers do
  def policy(record, policy_class = nil)
    policy_class ||= Object.const_get("#{record.class.name}Policy")
    policy_class.new(Current.user, record)
  end

  def authorize!(record, action, policy_class: nil)
    return if policy(record, policy_class).public_send(action)
    halt 403, erb(:"errors/forbidden")     # :forbidden
  end

  def policy_scope(dataset, scope_class)
    scope_class.new(Current.user, dataset).resolve
  end
end
```

Route usage — `authorize!` halts `403`; `policy_scope` filters lists:

```ruby
# app/routes/notes.rb
get "/notes" do
  @notes = policy_scope(Note.dataset, NotePolicy::Scope).all
  erb :"notes/index"
end

post "/notes/:id" do
  note = Current.account.notes_dataset.first(id: params[:id]) or halt 404
  authorize!(note, :update?)
  Notes::Update.call(actor: Current.user, account: Current.account,
                     note_id: note.id, attrs: note_params)
    .either(->(n) { redirect "/notes/#{n.id}" },
            ->(_) { halt 403 })
end
```

Rails leans on `after_action :verify_authorized` to prove a route didn't forget
to authorize. Sinatra has **no framework-enforced equivalent** — the honest
approximation is opt-in: have `authorize!` set `@_authorized = true` and assert it
in an `after` filter for routes that mutate. Treat it as a lint, not a guarantee;
the real boundary is the service (§4).

### Central ability object <span title="mature">`[mature]`</span> — alternative

Instead of per-resource policies, a single hand-rolled `Ability` maps an actor to
permitted actions in one place — the CanCanCan idea without the gem:

```ruby
# app/policies/ability.rb
class Ability
  def initialize(user, account)
    @m = account.memberships_dataset.first(user_id: user.id)
  end

  def can?(action, record)
    case [action, record.class.name]
    in [:update,  "Note"] then @m&.role_at_least?(:editor)
    in [:destroy, "Note"] then @m&.role_at_least?(:admin)
    else false
    end
  end
end
# route: halt 403 unless Ability.new(Current.user, Current.account).can?(:update, note)
```

### Per-resource policies vs one central ability

| Want | Pick | Why |
|---|---|---|
| Per-resource policy objects, explicit `authorize!` calls | **policy objects** | Logic co-located with the resource; easy to spec in isolation |
| One central ability map | **`Ability`** | Fewer files; rules readable in one place |
| A `Scope` for list filtering as a first-class idiom | **policy objects** | Scope is a named inner class per resource |
| Lots of similar rules across many models | **`Ability`** | One central definition |
| Default for this template | **policy objects** | Matches `separation-of-concerns.md` baseline |

Don't run both. Neither uses a gem — they are plain Ruby you own.

---

## 4. Enforce in routes AND re-check in services (defense in depth)

The route is the first gate, **not the only gate**. A service may be called by a
Sinatra route today and a Sidekiq job, a JSON endpoint, or a Rake task tomorrow —
none of which ran the route's `authorize!`. So the **service authorizes too**.

```ruby
# ✅ service is the real boundary — it authorizes regardless of caller
module Notes
  class Update
    include Dry::Monads[:result]

    def self.call(...) = new(...).call

    def initialize(actor:, account:, note_id:, attrs:)
      @actor, @account, @note_id, @attrs = actor, account, note_id, attrs
    end

    def call
      note = @account.notes_dataset.first(id: @note_id) or
        return Failure([:not_found])                          # tenant scope
      return Failure([:forbidden]) unless
        NotePolicy.new(@actor, note).update?                  # authorization

      note.update(@attrs)
      Success(note)
    rescue Sequel::ValidationFailed
      Failure([:validation, note.errors])
    end
  end
end
```

```ruby
# ❌ service trusts that "the route already checked" — false for job/API/Rake callers
def call
  @account.notes_dataset.first(id: @note_id).update(@attrs)   # no policy → privilege escalation
  Success(...)
end
```

**Views** show/hide UI with the policy — never re-derive the rule:

```erb
<%# ✅ %>
<% if policy(note).update? %>
  <a href="/notes/<%= note.id %>/edit" data-testid="edit-note">Edit</a>
<% end %>

<%# ❌ %>
<% if Current.membership.role == "admin" %>
  <a href="/notes/<%= note.id %>/edit">Edit</a>
<% end %>
```

---

## 5. Super admin — bypass scope only in an Admin namespace

A platform operator sometimes needs to cross tenant boundaries (support, billing
ops). Model it as a **platform-level flag** on `users` (not a membership role),
and let it bypass tenant scope **only inside an explicit `Admin` app** — never in
tenant-facing code.

```ruby
class User < Sequel::Model
  # platform flag — distinct from per-account Membership roles (§2)
  # migration: add_column :users, :super_admin, TrueClass, null: false, default: false
end
```

Sinatra has no controller namespaces. The honest equivalent is a **separate
`Sinatra::Base` app mounted under `/admin`** in `config.ru` (or
`register Sinatra::Namespace` from `sinatra-contrib` for an in-app prefix):

```ruby
# ❌ super-admin check leaking into tenant code — every read now branches on it
get "/notes" do
  @notes = Current.user.super_admin? ? Note.dataset : Current.account.notes_dataset
end
```

```ruby
# ✅ tenant routes always scope; cross-tenant access is a separate mounted app
# config.ru
map("/admin") { run Admin::App }

# app/admin/app.rb
class Admin::App < Sinatra::Base
  before do
    halt 403 unless Current.user&.super_admin?   # the ONLY place scope is bypassed
  end

  get "/notes" do
    @notes = Note.dataset      # documented cross-scope read
    erb :"admin/notes/index"
  end
end
```

Cross-scope `Admin` access is the documented exception (see `multi-tenancy.md`).
Audit every super-admin action, including impersonation context (see
`architecture-decisions.md`).

---

## 6. Anti-patterns — never compare role strings inline

A bare string/predicate comparison scattered through routes and views is the
classic RBAC bug: the hierarchy is implicit, untestable, and drifts.

```ruby
# ❌ implicit hierarchy, duplicated everywhere, breaks when roles change
redirect "/" unless membership.role == "admin"
@can_edit = membership.role == "admin" || membership.role == "owner"
halt 403 unless %w[admin owner].include?(membership.role)
```

```ruby
# ✅ one helper / one policy owns the hierarchy
authorize!(note, :update?)                   # in a route
membership.role_at_least?(:admin)            # the hierarchy helper (§2)
policy(note).update?                         # in a view
```

| Smell | Fix |
|---|---|
| `role == "admin"` | `role_at_least?(:admin)` or a policy predicate |
| `%w[admin owner].include?(role)` | `role_at_least?(:admin)` (hierarchy) |
| Role check in a view | `policy(record).action?` |
| Role check in a route `if` | `authorize!(record, :action?)` |
| `super_admin?` inside tenant code | move to the `Admin` app (§5) |

---

## 7. Tests — three axes per protected action

Every protected action gets **three** tests. Authorization bugs hide in the gaps
between them, so all three are mandatory.

| Axis | Setup | Expect |
|---|---|---|
| **Sufficient role succeeds** | actor with role ≥ required, in scope | `Success` / `2xx`/`3xx` |
| **Insufficient role denied** | actor in the account but role too low | `Failure([:forbidden])` / `403` |
| **Different account denied** | actor with a high role but in **another** account | `Failure([:not_found])` (scope) — not `403` |

The third axis is the one people forget: a different-account actor must be
rejected by **scope** (`:not_found`), proving authorization never even runs on
out-of-scope rows. That keeps layers 2 and 3 (§the three layers) honest.

### Policy specs <span title="stable">`[stable]`</span>

No gem ships `permit_action`/`forbid_action` matchers here — the policy is plain
Ruby, so assert the predicate directly with RSpec. Each example runs inside a
rolled-back Sequel transaction (see `testing.md`):

```ruby
# spec/policies/note_policy_spec.rb
RSpec.describe NotePolicy do
  subject(:policy) { described_class.new(user, note) }

  let(:account) { create(:account) }
  let(:note)    { create(:note, account:) }

  context "editor in the account" do
    let(:user) { create_membership(account, :editor).user }
    it { expect(policy.update?).to be(true)  }   # axis 1
    it { expect(policy.destroy?).to be(false) }  # axis 2 (needs admin)
  end

  context "admin in a different account" do
    let(:user) { create_membership(create(:account), :admin).user }
    it { expect(policy.update?).to be(false) }   # axis 3 — wrong account
  end
end
```

Spec the **`Scope`** class too (`NotePolicy::Scope`) — confirm `#resolve` returns
in-account rows and excludes others. And per the project rule: every policy
predicate and every `Failure` branch in the service gets a test.

---

## Gem reference (loose pins)

| Gem | Pin | Maturity | Role |
|---|---|---|---|
| `bcrypt` | `~> 3.1` | <span title="stable">`[stable]`</span> | Password hashing (`#password=` / `#authenticate`) |
| `sequel_secure_password` | `~> 0.3` | <span title="mature">`[mature]`</span> | Sequel plugin wrapping `bcrypt` (removes boilerplate) |
| `warden` | `~> 1.2` | <span title="mature">`[mature]`</span> | Rack authentication framework (pluggable strategies) |
| `omniauth` | `~> 2.1` | <span title="mature">`[mature]`</span> | Third-party / OAuth login |

**Authorization needs no gem** — policy objects and the `authorize!` helper are
plain Ruby you own in `app/policies/` and `app.rb`. The signed session cookie is
built into Rack/Sinatra (`Rack::Session::Cookie`).

---

## Related docs

- `separation-of-concerns.md` — route vs service boundary; where `authorize!` is called; `Current` scope-vs-authorization
- `multi-tenancy.md` — tenant scoping, the current-account dataset, the `Admin` cross-scope exception
- `database.md` — Sequel models/datasets, migrations, the single-writer SQLite constraint, Litestream
- `architecture-decisions.md` — Result/error tags (`:forbidden`, `:not_found`), audit logging (ownership transfer, super-admin actions)
- `testing.md` — RSpec / Rack::Test / Capybara patterns, FactoryBot, rolled-back transactions
