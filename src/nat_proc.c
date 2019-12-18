#include "natalie.h"
#include "nat_proc.h"

NatObject *Proc_call(NatEnv *env, NatObject *self, size_t argc, NatObject **args, struct hashmap *kwargs, NatBlock *block) {
    NAT_ASSERT_ARGC(0); // for now
    assert(self->type == NAT_VALUE_PROC);
    return nat_run_block(env, self->block, argc, args, kwargs, block);
}
