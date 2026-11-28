package core

import (
	"context"
	"errors"
	"net/url"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/proxydialer"
	C "github.com/metacubex/mihomo/constant"
)

// Optional source contract. A released older engine has no implementation;
// the adapter compiles against it without ever faking a live dialer identity.
type chainProbeSource interface {
	ChainProbeSource() (C.Dialer, func(func(C.Dialer) C.Dialer) (C.Proxy, error), bool)
}

type nativeChainHealthGroup interface {
	SetChainHealthEnabled(bool)
	RunChainHealth(context.Context, C.Proxy, C.Dialer, outboundgroup.ChainProbeOwnerFactory, string, uint16, time.Duration, func([]outboundgroup.ChainProbeResult,error)) error
}

func chainHealthAvailable() bool {
	_,ok := any((*adapter.Proxy)(nil)).(chainProbeSource)
	return ok
}

type chainHealthOwner struct {
	Name string `json:"name"`
	Group string `json:"group"`
	Provider string `json:"provider"`
	Identity string `json:"identity"`
}

type chainHealthRequest struct {
	Name string `json:"name"`
	Group string `json:"group"`
	Identity string `json:"identity"`
	Enabled bool `json:"enabled"`
}

type chainHealthJobStatus struct {
	Owner chainHealthOwner `json:"owner"`
	Results []outboundgroup.ChainProbeResult `json:"results"`
	Error string `json:"error,omitempty"`
}

type chainHealthJob struct {
	group nativeChainHealthGroup
	cancel context.CancelFunc
	status chainHealthJobStatus
}

var chainHealthJobs = struct{
	sync.Mutex
	jobs map[string]*chainHealthJob
}{jobs:make(map[string]*chainHealthJob)}

func describeChainHealthOwner(proxy C.Proxy) (chainHealthOwner,C.Dialer,outboundgroup.ChainProbeOwnerFactory,bool) {
	if proxy==nil { return chainHealthOwner{},nil,nil,false }
	source,ok:=proxy.(chainProbeSource)
	if !ok {return chainHealthOwner{},nil,nil,false}
	group:=proxy.ProxyInfo().DialerProxy
	dialer,factory,ok:=source.ChainProbeSource()
	if !ok || factory==nil {return chainHealthOwner{},nil,nil,false}
	id,ok:=proxydialer.NamedDialerIdentity(dialer,group)
	if !ok {return chainHealthOwner{},nil,nil,false}
	return chainHealthOwner{Name:proxy.Name(),Group:group,Provider:proxy.ProxyInfo().ProviderName,Identity:strconv.FormatUint(id,10)},dialer,outboundgroup.ChainProbeOwnerFactory(factory),true
}

func handleGetChainHealth() map[string]any {
	owners:=[]chainHealthOwner{}
	if chainHealthAvailable() {
		proxies:=allProxies()
		names:=make([]string,0,len(proxies))
		for name:=range proxies {names=append(names,name)}
		sort.Strings(names)
		for _,name:=range names {
			p:=proxies[name]
			owner,_,_,ok:=describeChainHealthOwner(p)
			if !ok {continue}
			if _,ok:=adapterAs[nativeChainHealthGroup](proxies[owner.Group]);!ok {continue}
			owners=append(owners,owner)
			if len(owners)>=256 {break}
		}
	}
	chainHealthJobs.Lock()
	defer chainHealthJobs.Unlock()
	jobs:=make([]chainHealthJobStatus,0,len(chainHealthJobs.jobs))
	for _,job:=range chainHealthJobs.jobs {
		status:=job.status
		status.Results=append([]outboundgroup.ChainProbeResult(nil),status.Results...)
		jobs=append(jobs,status)
	}
	sort.Slice(jobs,func(i,j int)bool{return jobs[i].Owner.Group<jobs[j].Owner.Group})
	return map[string]any{"available":chainHealthAvailable(),"owners":owners,"jobs":jobs}
}

func stopChainHealthLocked(group string) {
	if job:=chainHealthJobs.jobs[group];job!=nil {
		delete(chainHealthJobs.jobs,group)
		job.cancel()
		job.group.SetChainHealthEnabled(false)
	}
}

func stopAllChainHealth() {
	chainHealthJobs.Lock()
	defer chainHealthJobs.Unlock()
	for name:=range chainHealthJobs.jobs {stopChainHealthLocked(name)}
}

func handleSetChainHealth(request chainHealthRequest) (bool,error) {
	configMu.Lock()
	defer configMu.Unlock()
	chainHealthJobs.Lock()
	defer chainHealthJobs.Unlock()
	if !request.Enabled {
		if job:=chainHealthJobs.jobs[request.Group];job!=nil && job.status.Owner.Identity==request.Identity {
			stopChainHealthLocked(request.Group)
		}
		return true,nil
	}
	if !chainHealthAvailable() {return false,errors.New("active chain health is unavailable in this engine")}
	if !isRunning.Load() {return false,errors.New("core listeners are stopped")}
	if len(chainHealthJobs.jobs)>=8 {return false,errors.New("active chain health group limit reached")}
	if chainHealthJobs.jobs[request.Group]!=nil {return false,errors.New("a probe owner is already selected for this group")}
	proxies:=allProxies()
	owner:=proxies[request.Name]
	groupProxy:=proxies[request.Group]
	desc,dialer,factory,ok:=describeChainHealthOwner(owner)
	if !ok || desc.Group!=request.Group || desc.Identity!=request.Identity {
		return false,errors.New("chain owner changed; refresh the list")
	}
	group,ok:=adapterAs[nativeChainHealthGroup](groupProxy)
	if !ok {return false,errors.New("not an automatic chain group")}
	testURL:=currentTestURL()
	u,err:=url.Parse(testURL)
	if err!=nil || u.Scheme!="https" || u.Hostname()=="" || u.User!=nil || u.Fragment!="" {
		return false,errors.New("chain health requires an HTTPS test URL returning 204")
	}
	ctx,cancel:=context.WithCancel(context.Background())
	job:=&chainHealthJob{group:group,cancel:cancel,status:chainHealthJobStatus{Owner:desc,Results:[]outboundgroup.ChainProbeResult{}}}
	group.SetChainHealthEnabled(true)
	chainHealthJobs.jobs[request.Group]=job
	// Never recreate an owner from a stale provider or profile. Identity
	// includes the exact original named dialer; same-name replacements fail.
	valid:=func()bool{
		current:=allProxies()
		return ctx.Err()==nil && current[request.Name]==owner && current[request.Group]==groupProxy
	}
	scoped:=func(bind func(C.Dialer) C.Dialer)(C.Proxy,error){
		if !valid(){cancel();return nil,errors.New("chain owner or group replaced")}
		return factory(bind)
	}
	go func(){
		defer func(){
			chainHealthJobs.Lock()
			defer chainHealthJobs.Unlock()
			if chainHealthJobs.jobs[request.Group]==job {stopChainHealthLocked(request.Group)}
		}()
		// The native scheduler serializes rounds and respects all-fail,
		// manual choices, expiration and verified TCP-only alternatives.
		_ = group.RunChainHealth(ctx,owner,dialer,scoped,testURL,204,15*time.Second,func(results []outboundgroup.ChainProbeResult,err error){
			if !valid(){cancel();return}
			chainHealthJobs.Lock()
			defer chainHealthJobs.Unlock()
			if chainHealthJobs.jobs[request.Group]!=job{return}
			job.status.Results=append([]outboundgroup.ChainProbeResult(nil),results...)
			job.status.Error=""
			if err!=nil{job.status.Error=err.Error()}
		})
	}()
	return true,nil
}
