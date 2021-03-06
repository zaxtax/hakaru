# Step 2 of 3: computer algebra

improve := proc(lo :: LO(name, anything), {_ctx :: t_kb := empty}, opts := [], $)
local r, `&context`;
  userinfo(5, improve, "input: ", print(lo &context _ctx));
  _Env_HakaruSolve := true;
  r:= LO(op(1,lo), reduce(op(2,lo), op(1,lo), _ctx, opts));
  userinfo(5, improve, "output: ", print(r));
  r
end proc;

# Walk through integrals and simplify, recursing through grammar
# h - name of the linear operator above us
# kb - domain information
reduce := proc(ee, h :: name, kb :: t_kb, opts := [], $)
  local e, elim, subintegral, w, ww, x, c, kb1, with_kb1, dom_specw, dom_specb
       , body, dom_spec, ed, mkDom, vars, rr
       , do_domain := evalb( not ( "no_domain" in {op(opts)} ) ) ;
  e := ee;

  if do_domain then
    rr := reduce_Integrals(e, h, kb, opts);
    if rr <> FAIL then return rr end if;
  end if;
  if e :: 'applyintegrand(anything, anything)' then
    map(simplify_assuming, e, kb)
  elif e :: `+` then
    map(reduce, e, h, kb, opts)
  elif e :: `*` then
    (subintegral, w) := selectremove(depends, e, h);
    if subintegral :: `*` then error "Nonlinear integral %1", e end if;
    subintegral := convert(reduce(subintegral, h, kb, opts), 'list', `*`);
    (subintegral, ww) := selectremove(depends, subintegral, h);
    simplify_factor_assuming(`*`(w, op(ww)), kb)
      * `*`(op(subintegral));
  elif e :: Or(Partition,t_pw) then
    if e :: t_pw then e := PWToPartition(e); end if;
    e := Partition:-Simpl(e);
    e := kb_Partition(e, kb, simplify_assuming,
                      ((rhs, kb) -> %reduce(rhs, h, kb, opts)));
    e := eval(e, %reduce=reduce);
    # big hammer: simplify knows about bound variables, amongst many
    # other things
    Testzero := x -> evalb(simplify(x) = 0);
    e := Partition:-Simpl(e);
    if ee::t_pw and e :: Partition then
      e := Partition:-PartitionToPW(e);
    end if;
    e;
  elif e :: t_case then
    subsop(2=map(proc(b :: Branch(anything, anything))
                   eval(subsop(2='reduce'(op(2,b),x,c,opts),b),
                        {x=h, c=kb})
                 end proc,
                 op(2,e)),
           e);
  elif e :: 'Context(anything, anything)' then
    kb1 := assert(op(1,e), kb);
    # A contradictory `Context' implies anything, so produce 'anything'
    # In particular, 42 :: t_Hakaru = false, so a term under a false
    # assumption should never be inspected in any way.
    if kb1 :: t_not_a_kb then
        return 42
    end if;
    applyop(reduce, 2, e, h, kb1, opts);
  elif e :: 'toLO:-integrate(anything, Integrand(name, anything), list)' then
    x := gensym(op([2,1],e));
    # If we had HType information for op(1,e),
    # then we could use it to tell kb about x.
    subsop(2=Integrand(x, reduce(subs(op([2,1],e)=x, op([2,2],e)), h, kb, opts)), e)
  else
    simplify_assuming(e, kb)
  end if;
end proc;

# "Integrals" refers to any types of "integrals" understood by domain (Int,
# Sum currently)
reduce_Integrals := module()
  export ModuleApply;
  local
  # The callbacks passed by reduce_Integrals to Domain:-Reduce
    reduce_Integrals_body, reduce_Integrals_into
  # tries to evaluate a RootOf
  , try_eval_Root
  # tries to evaluate Int/Sum/Ints/Sums
  , elim_intsum;

  reduce_Integrals_body := proc(h,opts,x,kb1) reduce(x,h,kb1,opts) end proc;
  reduce_Integrals_into := proc(h,opts,kind,e,vn,vt,kb,$)
    local rr;
    rr := elim_intsum(Domain:-Apply:-do_mk(args[3..-1]), h, kb,opts);
    rr := subsindets(rr, specfunc(RootOf), x->try_eval_Root(x,a->a));
    return rr;
  end proc;

  ModuleApply := proc(expr, h, kb, opts, $)
    local rr;
    rr := Domain:-Reduce(expr, kb
      ,curry(reduce_Integrals_into,h,opts)
      ,curry(reduce_Integrals_body,h,opts)
      ,(_->:-DOM_FAIL));
    rr := kb_assuming_mb(Partition:-Simpl)(rr, kb, x->x);
    if has(rr, :-DOM_FAIL) then
      return FAIL;
    elif has(rr, FAIL) then
      error "Something strange happened in reduce_Integral(%a, %a, %a, %a)\n%a"
           , expr, kb, kb, opts, rr;
    end if;
    rr;
  end proc;

  try_eval_Root := proc(e0::specfunc(`RootOf`),on_fail := (_->FAIL), $)
    local ix,e := e0;
    try
      if nops(e)=2 or nops(e)=3
      and op(-1,e) :: `=`(identical(index),{specindex(real),nonnegint}) then
        ix := op([2,-1],e);
        if ix :: specindex(real) then ix := op(ix); end if;
        e := op(0,e)(op(1,e));
      else
        ix := NULL;
      end if;
      e := convert(e, 'radical', ix);
      if e :: specfunc(RootOf) then return on_fail(e) end if;
      return e;
    catch: return on_fail(e0); end try;
  end proc;

  # Try to find an eliminate (by evaluation, or simplification) integrals which
  # are free of `applyintegrand`s.
  elim_intsum := module ()
    export ModuleApply := proc(inert0, h :: name, kb :: t_kb, opts, $)
       local ex, e, inert := inert0;
       ex := extract_elim(inert, h, kb);
       e[0] := apply_elim(h, kb, ex);
       e[1] := check_elim(inert, e[0]);
       if e[1] = FAIL then inert
       else
         e[2] := reduce(e[1],h,kb,opts);
         if has(e[2], {csgn}) then
           WARNING("Throwing away an eliminated result result containing csgn (this "
                   "could be a bug!):\n%1\n(while running %2)", e[2], ex);
           inert;
         else e[2] end if;
       end if
    end proc;

    local known_tys := table([Int=int_assuming,Sum=sum_assuming,Ints=ints,Sums=sums]);
    local extract_elim := proc(e, h::name, kb::t_kb,$)
      local t, intapps, var, f, e_k, e_args, vs, blo, bhi;
      vs := {op(KB:-kb_to_variables(kb))};
      t := 'applyintegrand'('identical'(h), 'anything');
      intapps := indets(op(1,e), t);
      if intapps = {} then
        return FAIL;
      end if;
      e_k := op(0,e); e_args := op([2..-1],e);
      if Domain:-Has:-Bound(e) and assigned(known_tys[e_k]) then
        var := Domain:-ExtBound[e_k]:-ExtractVar(e_args);
        ASSERT(var::DomBoundVar);
        blo, bhi := Domain:-ExtBound[e_k]:-SplitRange
                    (Domain:-ExtBound[e_k]:-ExtractRange(e_args));
        if ormap(b->op(1,b) in map((q-> (q,-q)), vs) and op(2,b)::SymbolicInfinity
                ,[[blo,bhi],[bhi,blo]]) then
          return FAIL end if;
        if var :: list then var := op(1,var) end if;
        if not depends(intapps, var) then
          f := known_tys[e_k];
        else
          return FAIL;
        end if;
      end if;
      [ op(1,e), f, var, [e_args] ];
    end proc;

    local apply_elim := proc(h::name,kb::t_kb,todo::{list,identical(FAIL)})
      local body, f, var, rrest;
      if todo = FAIL then return FAIL; end if;
      body, f, var, rrest := op(todo);
      banish(body, h, kb, infinity, var,
             proc (kb1,g,$) do_elim_intsum(kb1, f, g, op(rrest)) end proc);
    end proc;

    local check_elim := proc(e, elim,$)
      if has(elim, {MeijerG, undefined, FAIL}) or e = elim or elim :: SymbolicInfinity then
        return FAIL;
      end if;
      return elim;
    end proc;

    local do_elim_intsum := proc(kb, f, ee, v::{name,name=anything})
      local w, e, x, g, t, r;
      w, e := op(Domain:-Extract:-Shape(ee));
      w := Domain:-Shape:-toConstraints(w);
      e := piecewise_And(w, e, 0);
      e := f(e,v,_rest,kb);
      x := `if`(v::name, v, lhs(v));
      g := '{sum, sum_assuming, sums}';
      if f in g then
        t := {'identical'(x),
              'identical'(x) = 'Not(range(Not({SymbolicInfinity, undefined})))'};
      else
        g := '{int, int_assuming, ints}';
        t := {'identical'(x),
              'identical'(x) = 'anything'};
        if not f in g then g := {f} end if;
      end if;
      for r in indets(e, 'specfunc'(g)) do
        if 1<nops(r) and op(2,r)::t then return FAIL end if
      end do;
      e
    end proc;
  end module; # elim
end module; # reduce_Integrals

int_assuming := proc(e, v::name=anything, kb::t_kb, $)
  simplify_factor_assuming('int'(e, v), kb);
end proc;

sum_assuming := proc(e, v::name=anything, kb::t_kb)
  simplify_factor_assuming('sum'(e, v), kb);
end proc;

# Int( .., var=var_ty ) == var &X var_ty
isBound_IntSum := kind -> module()
  option record;
  export MakeKB := (`if`(kind=Sum,KB:-genSummation,KB:-genLebesgue));
  export ExtractVar := (e->op(1,e));
  export ExtractRange := (e->op(2,e));
  export MakeRange := `..`;
  export SplitRange := (e->op(e));
  export Constrain := `if`(kind=Sum,`<=`,`<`);
  export DoMk := ((e,v,t)->kind(e,v=t));
  export Min := `min`; export Max := `max`;
  export VarType := 'name';
  export RangeType := 'range';
  export MapleType := 'And'('specfunc'(kind), 'anyfunc(anything,name=range)');
  export BoundType := `if`(kind=Sum,'integer','real');
  export RecogBound := `if`(kind=Sum,
            (proc(k,b)
               if   k = `<=` then (x->subsop(2=b,x))
               elif k = `>=` then (x->subsop(1=b,x))
               elif k = `<`  then (x->subsop(2=(b-1),x))
               elif k = `>`  then (x->subsop(1=b+1,x))
               end if;
             end proc),
            (proc(k,b)
               if   k in {`<=`,`<`} then (x->subsop(2=b,x))
               elif k in {`>=`,`>`} then (x->subsop(1=b,x))
               end if;
             end proc));
end module;

# Ints( .., var::name, var_ty::range, dims::list(name=range) ) ==
#        [ var   , map(lhs,dims) ] :: list(name)  &X
#        [ var_ty, map(rhs,dims) ] :: list(range)
isBound_IntsSums := kind -> module()
  option record;
  export MakeKB := proc(vars, lo, hi, kb, $)
    local var, dims, ty, rngs, x, kb1;
    var  := op(1, vars);
    rngs := zip(`..`,lo,hi);
    ty   := op(1, rngs);
    dims := subsop(1=NULL,zip(`=`,vars,rngs));
   x, kb1 := genType(var,
                      mk_HArray(`if`(kind=Ints,
                                     HReal(open_bounds(ty)),
                                     HInt(closed_bounds(ty))),
                                dims),kb);
    if nops(dims) > 0 then
      kb1 := assert(size(x)=op([-1,2,2],dims)-op([-1,2,1],dims)+1, kb1);
    end if;
    x, kb1;
  end proc;
  export ExtractVar   := ((v,t,d)->[v,map(lhs,d)[]]);
  export ExtractRange := ((v,t,d)->[t,map(rhs,d)[]]);
  export MakeRange    := ((a,b)->zip(`..`,a,b));
  export SplitRange   := (rs->(map(x->op(1,x),rs), map(x->op(2,x),rs)));
  export Constrain    := ((a,b)->zip(`if`(kind=Ints, `<`, `<=`),a,b)[]);
  export DoMk         := ((e,v,t)->kind( e,op(1,v),op(1,t), subsop(1=NULL,zip(`=`,v,t)) ));
  export Min          := ((a,b)->zip(`min`,a,b));
  export Max          := ((a,b)->zip(`max`,a,b));
  export VarType      := 'And(list(name),satisfies(x->x<>[]))';
  export RangeType    := 'And(list(range),satisfies(x->x<>[]))';
  export MapleType    := 'And'('specfunc'(kind),'anyfunc'('anything', 'name', 'range', 'list(name=range)'));
  export BoundType    := TopProp;
  export RecogBound   := (_->NULL);
end module;
