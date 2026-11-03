#include "memory.h"
#include "region.h"

#include <l4/cxx/minmax>

unsigned long
Memory::find_free_ram(unsigned long size,
                      unsigned long min_addr,
                      unsigned long max_addr,
                      unsigned align,
                      unsigned node)
{
  unsigned long min = cxx::max<unsigned long>(min_addr, sizeof(unsigned long));

  for (Region *rr = ram->begin(); rr != ram->end(); ++rr)
    {
      if (min >= rr->end())
        continue;
      if (max_addr <= rr->begin())
        continue;

      min = cxx::max(rr->begin(), min);

      Region search_area(min, cxx::min(rr->end(), max_addr));
      if (validate && !validate(&search_area, node))
        continue;

      for (;;)
        {
          Region *r = sysalloc->find(search_area);
          if (!r)
            break;

          Region int_area = r->intersect(search_area);
          if (unsigned long to = regions->find_free(int_area, size, align))
            return to;

          if (int_area.end() + 1 > search_area.end()
              || int_area.end() + 1 < int_area.end())
            break;

          search_area.begin(int_area.end() + 1);
        }
    }

  return 0;
}

unsigned long
Memory::find_free_ram_rev(unsigned long size,
                          unsigned long min_addr,
                          unsigned long max_addr,
                          unsigned align,
                          unsigned node)
{
  min_addr = cxx::max<unsigned long>(min_addr, sizeof(unsigned long));
  unsigned long max = max_addr;

  for (Region *rr = ram->end() - 1; rr >= ram->begin(); --rr)
    {
      if (min_addr >= rr->end())
        continue;
      if (max <= rr->begin())
        continue;

      max = cxx::min(rr->end(), max);

      Region search_area(cxx::max(rr->begin(), min_addr), max);
      if (validate && !validate(&search_area, node))
        continue;

      for (;;)
        {
          Region *r = sysalloc->find_rev(search_area);
          if (!r)
            break;

          Region int_area = r->intersect(search_area);
          if (unsigned long to = regions->find_free_rev(int_area, size, align))
            return to;

          // Note that search_area (and therefore int_area) will never start
          // below 'sizeof(long)' -- see min_addr above.
          if (int_area.begin() - 1 < search_area.begin())
            break;

          search_area.end(int_area.begin() - 1);
        }
    }

  return 0;
}
