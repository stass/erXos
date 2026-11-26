// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
//----------------------------------------------------------------------------
INTERFACE[rt_dbg]:

#include "spin_lock.h"
#include "lock_guard.h"
#include <cxx/dlist>
#include <cxx/hlist>
#include <cxx/dyn_cast>
#include "global_data.h"

struct Kobject_typeinfo_name
{
  cxx::Type_info const *type;
  char const *name;
};

#define JDB_DEFINE_TYPENAME(type, name) \
  static __attribute__((used, section(".debug.jdb.typeinfo_table"))) \
  Kobject_typeinfo_name const typeinfo_name__ ## type ## __entry =   \
    { cxx::Typeid<type>::get(), name }

class Kobject_dbg : public cxx::D_list_item
{
  friend class Jdb_mapdb;

public:
  class Dbg_extension : public cxx::H_list_item
  {
  public:
    virtual ~Dbg_extension() = 0;
  };

public:
  typedef cxx::H_list<Dbg_extension> Dbg_ext_list;
  Dbg_ext_list _jdb_data;

private:
  Mword _dbg_id;

public:
  Mword dbg_id() const { return _dbg_id; }

  virtual cxx::_dyn::Type _cxx_dyn_type() const = 0;
  virtual ~Kobject_dbg() = 0;


  typedef cxx::D_list<Kobject_dbg> Kobject_list;
  typedef Kobject_list::Iterator Iterator;
  typedef Kobject_list::Const_iterator Const_iterator;

  static Global_data<Spin_lock<>> _kobjects_lock;
  static Global_data<Kobject_list> _kobjects;

  static Iterator begin() { return _kobjects->begin(); }
  static Iterator end() { return _kobjects->end(); }

private:
  static Global_data<unsigned long> _next_dbg_id;
};

//----------------------------------------------------------------------------
INTERFACE[!rt_dbg]:

#define JDB_DEFINE_TYPENAME(type, name)

class Kobject_dbg
{
public:
  typedef unsigned long Iterator;
};

//----------------------------------------------------------------------------
IMPLEMENTATION[rt_dbg]:

#include "static_init.h"

DEFINE_GLOBAL_PRIO(BOOTSTRAP_INIT_PRIO)
Global_data<Spin_lock<>> Kobject_dbg::_kobjects_lock;

DEFINE_GLOBAL_PRIO(BOOTSTRAP_INIT_PRIO)
Global_data<Kobject_dbg::Kobject_list> Kobject_dbg::_kobjects;

DEFINE_GLOBAL Global_data<unsigned long> Kobject_dbg::_next_dbg_id;

IMPLEMENT inline Kobject_dbg::Dbg_extension::~Dbg_extension() {}

PROTECTED
Kobject_dbg::Kobject_dbg()
{
  auto guard = lock_guard(&_kobjects_lock);

  _dbg_id = _next_dbg_id++;
  _kobjects->push_back(this);
}

IMPLEMENT inline
Kobject_dbg::~Kobject_dbg()
{
    {
      auto guard = lock_guard(&_kobjects_lock);
      _kobjects->remove(this);
    }

  while (Dbg_extension *ex = _jdb_data.front())
    delete ex;
}

//----------------------------------------------------------------------------
IMPLEMENTATION [!rt_dbg]:

PUBLIC constexpr
unsigned long
Kobject_dbg::dbg_id() const
{ return 0; }

PUBLIC static constexpr
unsigned long
Kobject_dbg::dbg_id(void const *)
{ return ~0UL; }

PUBLIC static constexpr
Kobject_dbg::Iterator
Kobject_dbg::pointer_to_obj(void const *)
{ return 0; }

PUBLIC static constexpr
unsigned long
Kobject_dbg::pointer_to_id(void const *)
{ return ~0UL; }

PUBLIC static constexpr
bool
Kobject_dbg::is_kobj(void const *)
{ return false; }

PUBLIC static constexpr
unsigned long
Kobject_dbg::obj_to_id(void const *)
{ return ~0UL; }
