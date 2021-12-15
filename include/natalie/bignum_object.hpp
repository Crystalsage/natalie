#pragma once

#include "natalie/big_int.hpp"
#include "natalie/integer_object.hpp"

namespace Natalie {

class BignumObject : public IntegerObject {
public:
    BignumObject(const String &num)
        : IntegerObject { -1 }
        , m_bignum(new BigInt(num)) { }

    BignumObject(const BigInt &other)
        : IntegerObject { -1 }
        , m_bignum(new BigInt(other)) { }

    BignumObject(const double &num)
        : IntegerObject { -1 }
        , m_bignum(new BigInt(num)) { }

    ~BignumObject() {
        if (m_bignum) delete m_bignum;
    }

    bool is_odd() override {
        if (m_bignum->to_string().length() != 0) {
            int last_digit = m_bignum->to_string().last_char() - '0';
            bool is_odd = last_digit % 2 != 0;
            return is_odd;
        }

        return true;
    }

    Value add(Env *, Value) override;
    Value sub(Env *, Value) override;
    Value mul(Env *, Value) override;
    Value div(Env *, Value) override;
    Value negate(Env *) override;
    Value to_s(Env *, Value = nullptr) override;

    bool eq(Env *, Value) override;
    bool lt(Env *, Value) override;
    bool lte(Env *, Value) override;
    bool gt(Env *, Value) override;
    bool gte(Env *, Value) override;

    bool is_bignum() const override { return true; }
    BigInt to_bignum() const override { return *m_bignum; }

    bool has_to_be_bignum() const {
        return *m_bignum > MAX_INT || *m_bignum < MIN_INT;
    }

    virtual void gc_inspect(char *buf, size_t len) const override {
        snprintf(buf, len, "<IntegerObject %p bignum=%s>", this, m_bignum->to_string().c_str());
    }

private:
    static inline const BigInt MAX_INT = NAT_INT_MAX;
    static inline const BigInt MIN_INT = NAT_INT_MIN;
    BigInt *m_bignum { nullptr };
};
}
